defmodule CrowdControl.Provider.Gce.API do
  @moduledoc """
  Every `gcp_compute` call in the project, and the error vocabulary built on
  top of it.

  The same confinement `CrowdControl.Backend.Docker.API` and
  `CrowdControl.Backend.Kubernetes.API` provide: one file to audit when the
  client library moves, and one place where `%GcpCompute.Error{}` becomes
  `{:error, {:gce, _}}`. `CrowdControl.Provider.Gce` never handles a
  `GcpCompute` struct — not even a successful one. `get_instance/3` and
  `list_all/3` return plain maps, which is also what lets the provider's tests
  build instances by hand.

  ## Vocabulary

    * `{:gce, {:not_found, message}}` — HTTP 404, wherever it surfaced.
      `Gce.release/1` treats it as success, which is what
      makes teardown idempotent.
    * `{:gce, {:http_status, status, message}}` — any other non-2xx.
    * `{:gce, {:transport, message}}` — the request never got an answer.
    * `{:gce, {:operation_timeout, message}}` — an `instances.insert` or
      `instances.delete` operation that did not reach `DONE` in time. **The
      instance may exist anyway**, which is why the provider rolls back on this.
    * `{:gce, {:operation_failed, message}}` — reached `DONE` carrying an error.
    * `{:gce, {:token_fetch_failed, message}}`, `{:gce, {:missing_token, _}}` —
      credentials, decided before the network.
    * `{:gce, {:bad_spec, message}}` — `GcpCompute.Instance.spec/1` rejected the
      options, before any VM existed.
    * `{:gce, {:bad_config, message}}` — no usable client config.
    * `{:gce, {:list_page_limit, pages}}` — pagination did not terminate. An
      error, never a short list; see `list_all/3`.

  Only messages travel, never `%GcpCompute.Error{}`'s `:body`: that field can
  hold the `Req` exception whose request headers carry the bearer token. The
  dep's own `Inspect` redacts it, but an error tuple that reaches a crash
  report or `Logger` metadata is not always rendered through `Inspect`.
  """

  # :gcp_compute is an optional dependency, so this module must still COMPILE
  # without it -- hence no struct patterns against any GcpCompute module
  # anywhere below (struct expansion needs the module at compile time; plain
  # `%{__struct__: Mod}` map patterns do not).
  # CrowdControl.Provider.Gce.acquire/1 raises a clear message at runtime if it
  # is genuinely missing.
  @compile {:no_warn_undefined,
            [GcpCompute, GcpCompute.Config, GcpCompute.Instance, GcpCompute.Instances]}

  # 500 per page: one owner's live sandboxes fit in a single round trip, and a
  # smaller page only multiplies the chances of a mid-pagination failure.
  @page_size 500

  # 50_000 instances is far beyond any plausible sandbox fleet, so hitting this
  # means the API echoed a page token forever. It is reported as an error
  # rather than capped into a short list -- see list_all/3.
  @max_pages 100

  @config_keys [:project, :zone, :token_provider, :base_url, :req_options, :allow_insecure]

  @typedoc """
  A `%GcpCompute.Config{}`.

  Opaque here on purpose: it belongs to the optional dep, it holds a live
  token-provider argument, and it must never reach a persisted handle.
  """
  @type config :: struct()

  @typedoc """
  One instance, flattened to plain data.

  `external_ip`/`internal_ip` are the first of each; `metadata` is the
  `metadata.items` list collapsed into a map, which is where the raw owner and
  the agent token live.
  """
  @type instance :: %{
          name: String.t() | nil,
          status: String.t() | nil,
          external_ip: String.t() | nil,
          internal_ip: String.t() | nil,
          created_at: DateTime.t() | nil,
          labels: %{optional(String.t()) => String.t()},
          metadata: %{optional(String.t()) => String.t()}
        }

  @doc """
  Raise unless the optional `:gcp_compute` dependency is available.

  Called from `Gce.acquire/1` only, so that merely
  loading this module — as `CrowdControl.Reaper` does when it walks configured
  backends — never raises.
  """
  @spec ensure_gcp_compute!() :: :ok
  def ensure_gcp_compute! do
    if Code.ensure_loaded?(GcpCompute.Config) do
      :ok
    else
      raise """
      CrowdControl.Provider.Gce requires the optional :gcp_compute dependency.

      Add it to your deps:

          {:gcp_compute, "~> 0.2"}
      """
    end
  end

  @doc """
  Build the client config for `opts`.

  Either a `%GcpCompute.Config{}` passed as `:gce_config`, or one built from
  `:project`, `:zone`, `:token_provider` (and the rest of
  `GcpCompute.Config.new/1`'s options).

  Application env under `:gce` fills in whatever `opts` omits. That fallback is
  the reattach path rather than a convenience: a persisted handle carries no
  token provider — it would be a live credential at rest — so the node that
  reconnects gets its client config from configuration, not from the `Store`
  record.

      config :crowd_control,
        gce: [project: "my-project", zone: "us-central1-a"]
  """
  @spec config(keyword()) :: {:ok, config()} | {:error, term()}
  def config(opts) do
    case opts[:gce_config] do
      nil ->
        build_config(opts)

      %{__struct__: GcpCompute.Config} = config ->
        {:ok, config}

      other ->
        {:error,
         {:gce,
          {:bad_config, ":gce_config must be a %GcpCompute.Config{}, got: #{inspect(other)}"}}}
    end
  end

  defp build_config(opts) do
    env = Application.get_env(:crowd_control, :gce, [])

    case GcpCompute.Config.new(Keyword.merge(env, Keyword.take(opts, @config_keys))) do
      {:ok, config} -> {:ok, config}
      {:error, message} -> {:error, {:gce, {:bad_config, message}}}
    end
  end

  @doc "The project a config points at."
  @spec project(config()) :: String.t()
  def project(config), do: config.project

  @doc """
  The zone a config points at.

  Read back out of the built config rather than out of the caller's options, so
  that `:gce_config` and `[project:, zone:]` produce identical handles and the
  library's own default zone can never disagree with the handle's.
  """
  @spec zone(config()) :: String.t()
  def zone(config), do: config.zone

  @doc """
  Build and validate the `instances.insert` body.

  Fails before anything is created, which is the only failure on the acquire
  path that needs no rollback.
  """
  @spec instance_spec(keyword()) :: {:ok, map()} | {:error, term()}
  def instance_spec(opts) do
    case GcpCompute.Instance.spec(opts) do
      {:ok, body} -> {:ok, body}
      {:error, message} -> {:error, {:gce, {:bad_spec, message}}}
    end
  end

  @doc """
  Create an instance and wait for the operation to finish.

  The operation, not the guest: this returns while Debian is still booting and
  the guest agent has not yet seen the SSH key. Reachability is
  `CrowdControl.Provider.Gce.Tunnel`'s problem and readiness is
  `GET /v1/health`'s.
  """
  @spec insert_and_wait(config(), map(), keyword()) :: {:ok, instance()} | {:error, term()}
  def insert_and_wait(config, spec, opts \\ []) do
    config |> GcpCompute.Instances.insert_and_wait(spec, opts) |> normalize_instance()
  end

  @doc "Read one instance."
  @spec get_instance(config(), String.t(), keyword()) :: {:ok, instance()} | {:error, term()}
  def get_instance(config, name, opts \\ []) do
    config |> GcpCompute.Instances.get(name, opts) |> normalize_instance()
  end

  @doc """
  Delete an instance and wait for the operation, treating 404 as success.

  Already-gone is the desired end state, which is what makes
  `Gce.release/1` idempotent across the several teardown
  paths that call it.
  """
  @spec delete_and_wait(config(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete_and_wait(config, name, opts \\ []) do
    case GcpCompute.Instances.delete_and_wait(config, name, opts) do
      {:ok, _operation} -> :ok
      {:error, error} -> tolerate_missing(reason(error))
    end
  end

  defp tolerate_missing({:gce, {:not_found, _}}), do: :ok
  defp tolerate_missing(reason), do: {:error, reason}

  @doc """
  Every instance matching `filter`, following `nextPageToken` to the last page.

  **Never** `GcpCompute.Instances.list/2`: it returns one page and no
  indication that there were more. A short list is not a cosmetic bug here.
  `CrowdControl.Reaper` reads this as *the* evidence of what is live, so a live
  sandbox missing from it is `live? = no, stored? = yes` — and the reaper
  deletes the store record of a running, billed VM, orphaning it permanently.
  Truncation must therefore be impossible, and any page failure surfaces as
  `{:error, _}` rather than a shorter list. This is the same hazard, and the
  same shape, as `CrowdControl.Backend.Kubernetes.API.list_all/3`.
  """
  @spec list_all(config(), String.t() | nil, keyword()) :: {:ok, [instance()]} | {:error, term()}
  def list_all(config, filter, opts \\ []) do
    paginate(config, filter, opts, nil, 1, [])
  end

  defp paginate(_config, _filter, _opts, _token, page, _acc) when page > @max_pages do
    {:error, {:gce, {:list_page_limit, @max_pages}}}
  end

  defp paginate(config, filter, opts, token, page, acc) do
    # Snake_case, and `gcp_compute` 0.3.0 now rejects anything it does not know
    # rather than passing it through to the wire. That is the better contract: the
    # camelCase spellings this used to send (`:maxResults`, `:pageToken`) were
    # silently forwarded as unrecognised query params, so the page size and the
    # page token had no effect at all — every call fetched the API server's
    # default first page, and pagination was a loop that could never advance.
    query =
      opts
      |> Keyword.take([:zone])
      |> Keyword.put(:max_results, @page_size)
      |> put_unless_nil(:filter, filter)
      |> put_unless_nil(:page_token, token)

    case GcpCompute.Instances.list_page(config, query) do
      {:ok, %{items: items, next_page_token: next}} when is_binary(next) and next != "" ->
        paginate(config, filter, opts, next, page + 1, [items | acc])

      {:ok, %{items: items}} ->
        {:ok, [items | acc] |> Enum.reverse() |> Enum.concat() |> Enum.map(&instance/1)}

      {:error, error} ->
        {:error, reason(error)}
    end
  end

  # --- normalization ---

  defp normalize_instance({:ok, instance}), do: {:ok, instance(instance)}
  defp normalize_instance({:error, error}), do: {:error, reason(error)}

  defp instance(instance) do
    %{
      name: instance.name,
      status: instance.status,
      external_ip: GcpCompute.Instance.external_ip(instance),
      internal_ip: GcpCompute.Instance.internal_ip(instance),
      created_at: instance.created_at,
      labels: instance.labels || %{},
      metadata: metadata(instance.raw)
    }
  end

  # No non-map clause: dialyzer proves every caller passes the decoded instance
  # map, so a fallback here is dead code it flags as pattern_match_cov.
  defp metadata(raw) do
    raw
    |> get_in(["metadata", "items"])
    |> List.wrap()
    |> Enum.filter(&is_binary(&1["key"]))
    |> Map.new(&{&1["key"], &1["value"]})
  end

  # A 404 is a 404 whichever field carried the status: `instances.delete` can
  # report it directly, and a delete whose operation completed with an error
  # reports it through `httpErrorStatusCode`. Both mean the same thing to
  # release/1.
  defp reason(%{__struct__: GcpCompute.Error, status: 404} = error),
    do: {:gce, {:not_found, message(error)}}

  defp reason(%{__struct__: GcpCompute.Error, reason: :api_error, status: status} = error)
       when is_integer(status),
       do: {:gce, {:http_status, status, message(error)}}

  defp reason(%{__struct__: GcpCompute.Error, reason: :timeout} = error),
    do: {:gce, {:operation_timeout, message(error)}}

  # Deliberately no catch-all, for the reason CrowdControl.Backend.Docker.API
  # already records: `GcpCompute` specs every failure as `%GcpCompute.Error{}`,
  # so the clause above already covers every value that can arrive and a
  # fallback is dead code dialyzer flags. If the dep ever violates its own spec
  # the result is a loud FunctionClauseError here rather than a silently
  # mistagged error — which is the trade this codebase makes everywhere else
  # (see `CrowdControl.Backend.safe/2` on why it catches `:exit` and nothing
  # more).
  defp reason(%{__struct__: GcpCompute.Error, reason: kind} = error),
    do: {:gce, {kind, message(error)}}

  defp message(%{message: message}) when is_binary(message), do: message
  defp message(%{reason: reason}), do: inspect(reason)

  defp put_unless_nil(query, _key, nil), do: query
  defp put_unless_nil(query, key, value), do: Keyword.put(query, key, value)
end
