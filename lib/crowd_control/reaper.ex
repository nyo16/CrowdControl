defmodule CrowdControl.Reaper do
  @moduledoc """
  Reconciles live sandboxes against stored session records.

  `Session.terminate/2` is best-effort and never runs on `SIGKILL`, a VM crash,
  or a hard container stop. For a local subprocess that does not matter much —
  the OS reaps it. For a *billed* remote sandbox it matters a great deal: the
  container keeps running and keeps costing money with nothing left to stop it.
  The reaper is the only real guarantee.

  ## Reconciliation

  For each configured backend, `list_live/1` is compared against `Store.all/0`:

  | live? | stored? | action |
  |---|---|---|
  | yes | yes | start a `CrowdControl.Session` in reattach mode |
  | yes | no  | **orphan** — `destroy/1` it |
  | no  | yes | stale record — `Store.delete/1` |

  Runs once at boot and then every `:sweep_interval` (default 5 minutes).

  ## Fail-open, always

  A backend whose `list_live/1` returns an error is **skipped** with a warning.
  It is never treated as "nothing is live". That misreading is the single most
  dangerous bug available here: one unreachable daemon would make every running
  sandbox look like a stale record, and the sweep would delete the lot. Every
  destructive branch requires positive evidence.

  ## Two-node safety

  Every sandbox carries its owner (`CrowdControl.Store.owner_id/0`, default
  `to_string(node())`), `list_live/1` filters on it, and the reaper only ever
  destroys sandboxes matching its own owner. Two nodes with independent stores
  therefore cannot reap each other's work. Callers sharing one backend across
  nodes with a *shared* store (Ecto, Redis) should set a single shared
  `:owner_id` — the owner stamp is the coordination primitive either way.

  `CrowdControl.Backend.Docker` stamps it as a `crowd_control.owner` label.
  `CrowdControl.Backend.Kubernetes` cannot: `nonode@nohost` is not a legal
  Kubernetes label value, and sanitizing it is lossy in exactly the way that
  lets one node's reaper destroy another's Pods. So it puts the raw owner in a
  `crowd_control.owner` *annotation*, whose values are unconstrained, and a
  sha256 prefix in a `crowd_control.owner_hash` label for the server-side
  selector. `owned_by?/3`'s local re-check still compares raw owners exactly,
  because `list_live/1` rebuilds each handle's owner from the annotation.

  A `:reap_grace_ms` window (default 60s), measured against the
  `crowd_control.created_at` label, protects a container created by a node that
  has not yet written its store record from being destroyed mid-provision.

  ## Configuration

      config :crowd_control,
        reaper: [
          backends: [{CrowdControl.Backend.Docker, image: "my-cli:latest"}],
          sweep_interval: :timer.minutes(5),
          reap_grace_ms: 60_000,
          reattach: true
        ]

  With no `:backends` configured the reaper starts and does nothing — there is
  no remote state to reconcile, which is the correct default for the local
  backend.
  """

  use GenServer

  require Logger

  alias CrowdControl.{Backend, Session, Store}

  @default_sweep_interval :timer.minutes(5)
  @default_grace_ms 60_000

  # --- Public API ---

  @doc false
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Run a reconciliation sweep now and return what it did.

  Synchronous; mainly for tests and operational pokes.
  """
  @spec sweep(GenServer.server(), timeout()) :: %{
          reattached: non_neg_integer(),
          destroyed: non_neg_integer(),
          pruned: non_neg_integer(),
          skipped: non_neg_integer()
        }
  def sweep(server \\ __MODULE__, timeout \\ 30_000) do
    GenServer.call(server, :sweep, timeout)
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    config = Keyword.merge(configured(), opts)

    state = %{
      backends: Keyword.get(config, :backends, []),
      sweep_interval: Keyword.get(config, :sweep_interval, @default_sweep_interval),
      grace_ms: Keyword.get(config, :reap_grace_ms, @default_grace_ms),
      reattach?: Keyword.get(config, :reattach, true),
      supervisor: Keyword.get(config, :supervisor, CrowdControl.SessionSupervisor)
    }

    # Boot reconciliation runs out-of-band so a slow or unreachable daemon
    # cannot block application startup. Disable with `sweep_on_boot: false` when
    # you want to drive sweeps yourself (tests do).
    if state.backends != [] and Keyword.get(config, :sweep_on_boot, true) do
      send(self(), :sweep)
    end

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    {:reply, reconcile(state), state}
  end

  @impl true
  def handle_info(:sweep, state) do
    if state.backends != [], do: reconcile(state)
    schedule(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --- Reconciliation ---

  defp reconcile(state) do
    empty = %{reattached: 0, destroyed: 0, pruned: 0, skipped: 0}

    Enum.reduce(state.backends, empty, fn backend_spec, acc ->
      {module, config} = normalize_backend(backend_spec)
      merge(acc, reconcile_backend(state, module, config))
    end)
  end

  defp reconcile_backend(state, module, config) do
    owner = config[:owner] || Store.owner_id()
    config = Keyword.put_new(config, :owner, owner)

    case safe_list_live(module, config) do
      {:ok, live} ->
        do_reconcile(state, module, owner, live)

      {:error, reason} ->
        # FAIL-OPEN. Never infer "nothing is live" from a failed listing --
        # doing so would destroy every running sandbox on the next sweep.
        Logger.warning(
          "Reaper: #{inspect(module)} list_live failed (#{inspect(reason)}); " <>
            "skipping this backend. No sandboxes will be destroyed or pruned."
        )

        %{reattached: 0, destroyed: 0, pruned: 0, skipped: 1}
    end
  end

  defp do_reconcile(state, module, owner, live) do
    records = records_for(module, owner)

    live_by_key = Map.new(live, &{session_key(&1), &1})
    stored_keys = MapSet.new(records, & &1.key)

    reattached = reattach_all(state, records, live_by_key)
    destroyed = destroy_orphans(state, module, live_by_key, stored_keys, owner)
    pruned = prune_stale(records, live_by_key)

    %{reattached: reattached, destroyed: destroyed, pruned: pruned, skipped: 0}
  end

  # live + stored -> reattach
  defp reattach_all(%{reattach?: false}, _records, _live), do: 0

  defp reattach_all(state, records, live_by_key) do
    records
    |> Enum.filter(&Map.has_key?(live_by_key, &1.key))
    |> Enum.count(fn record ->
      # Re-point the record at the handle the daemon just reported, which is
      # authoritative; the stored one may predate a restart.
      record = %{record | handle: Map.fetch!(live_by_key, record.key)}

      case start_session(state, record) do
        {:ok, _pid} ->
          Logger.info("Reaper: reattached session #{record.key}")
          true

        {:error, reason} ->
          Logger.warning("Reaper: failed to reattach #{record.key}: #{inspect(reason)}")
          false
      end
    end)
  end

  defp start_session(state, record) do
    DynamicSupervisor.start_child(state.supervisor, %{
      id: {Session, record.key},
      start: {Session, :start_reattached, [record]},
      restart: :transient
    })
  end

  # live + not stored -> orphan
  defp destroy_orphans(state, module, live_by_key, stored_keys, owner) do
    live_by_key
    |> Enum.filter(fn {key, handle} ->
      not MapSet.member?(stored_keys, key) and owned_by?(handle, owner, key)
    end)
    |> Enum.count(fn {key, handle} ->
      if within_grace?(module, handle, state.grace_ms) do
        Logger.debug("Reaper: #{inspect(key)} is inside the grace window; leaving it alone")
        false
      else
        Logger.info("Reaper: destroying orphaned sandbox #{inspect(key)}")
        module.destroy(handle)
        true
      end
    end)
  end

  # Ownership is filtered daemon-side by `list_live/1`, but destruction is
  # irreversible and this is the last gate before it, so re-check locally rather
  # than trusting one filter. A backend whose handle has no `:owner` concept at
  # all falls through (there is nothing to check); a handle that HAS the field
  # but carries nil or a foreign owner is refused.
  defp owned_by?(handle, owner, key) do
    if is_map(handle) and Map.has_key?(handle, :owner) do
      case Map.get(handle, :owner) do
        ^owner ->
          true

        other ->
          Logger.warning(
            "Reaper: refusing to destroy #{inspect(key)} — owner #{inspect(other)} " <>
              "does not match #{inspect(owner)}"
          )

          false
      end
    else
      true
    end
  end

  # A container younger than the grace period may belong to a session that has
  # provisioned but not yet written its record. Destroying it would be a race
  # the caller cannot win.
  defp within_grace?(module, handle, grace_ms) do
    if function_exported?(module, :age_ms, 1) do
      case module.age_ms(handle) do
        age when is_integer(age) -> age < grace_ms
        # Unknown age -> assume young and skip. Fail-open again: a missed reap
        # costs one sweep interval, a wrong reap costs a live session.
        _ -> true
      end
    else
      false
    end
  end

  # stored + not live -> stale
  defp prune_stale(records, live_by_key) do
    records
    |> Enum.reject(&Map.has_key?(live_by_key, &1.key))
    |> Enum.count(fn record ->
      Logger.info("Reaper: pruning stale record #{record.key}")
      Store.delete(record.key)
      true
    end)
  end

  # --- Helpers ---

  defp records_for(module, owner) do
    Enum.filter(Store.all(), &(&1.backend == module and &1.owner == owner))
  end

  defp session_key(handle) do
    case handle do
      %{session_key: key} when is_binary(key) -> key
      _ -> nil
    end
  end

  defp safe_list_live(module, config) do
    Backend.safe(fn -> module.list_live(config) end, {:error, :list_live_exited})
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp normalize_backend({module, config}) when is_atom(module) and is_list(config),
    do: {module, config}

  defp normalize_backend(module) when is_atom(module), do: {module, []}

  defp configured, do: Application.get_env(:crowd_control, :reaper, [])

  defp schedule(%{sweep_interval: interval}) when is_integer(interval) and interval > 0 do
    Process.send_after(self(), :sweep, interval)
  end

  defp schedule(_state), do: :ok

  defp merge(a, b) do
    Map.new(a, fn {k, v} -> {k, v + Map.fetch!(b, k)} end)
  end
end
