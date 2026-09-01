defmodule CrowdControl.Volume do
  @moduledoc """
  One volume-mount shape, shared by every substrate that can mount one.

  A sandbox is deliberately empty: the CLI, a FIFO, a tee file, and nothing
  else. Mounting is how real work gets in and out — a workspace to edit, a
  package cache worth reusing across sessions, a directory of fixtures.

  The shape is the same for Docker, Compose and Kubernetes, so a mount written
  for one substrate reads the same on the next:

      volumes: [
        %{name: "workspace", target: "/workspace"},
        %{host_path: "/srv/fixtures", target: "/fixtures", read_only: true}
      ]

  | Key | Meaning |
  |---|---|
  | `:name` | A managed volume: a Docker named volume, or a Kubernetes `PersistentVolumeClaim` of that name |
  | `:host_path` | A path on the machine running the container: a Docker bind mount, or a Kubernetes `hostPath` |
  | `:target` | Absolute path inside the sandbox. Required |
  | `:read_only` | Default `false` |

  Exactly one of `:name` or `:host_path`. They are separate keys rather than one
  overloaded `:source` because they are not the same decision: a named volume is
  storage this stack owns, and a host path is a hole into the machine. Code
  review can grep for one and not the other.

  ## What this does not do

  It does not create anything. A `:name` must already exist as a Docker volume
  or a bound PVC — `Provider.Compose` is the exception, since a Compose stack
  declares and owns its named volumes. Provisioning storage needs privileges
  running sandboxes does not justify, the same reasoning that keeps this library
  from creating Kubernetes namespaces.

  ## Security

  `:host_path` hands the sandbox part of the host filesystem. Under
  `read_only: true` that is a disclosure boundary; without it, it is a write
  boundary, and `/var/run/docker.sock` or a kubelet directory is a full escape.
  Untrusted model-driven code plus a writable host mount is not a sandbox. See
  `SECURITY.md`.

  A target may not collide with the paths the transport owns (`:fifo_path`,
  `:tee_path`, `:env_path`) or shadow their directories. Mounting over the FIFO
  does not fail loudly, it produces a sandbox whose reader never delivers a
  byte, so it is refused here instead.
  """

  @type t :: %{
          optional(:name) => String.t(),
          optional(:host_path) => String.t(),
          required(:target) => String.t(),
          optional(:read_only) => boolean()
        }

  @typedoc "A normalized mount: source kind, source, absolute target, read-only."
  @type normalized :: %{
          kind: :volume | :host_path,
          source: String.t(),
          target: String.t(),
          read_only: boolean()
        }

  @doc """
  Validates and normalizes `:volumes` from an option list.

  `reserved` are transport-owned paths the mounts must not collide with; pass
  the substrate's fifo, tee and env paths. Returns `{:ok, []}` when `:volumes`
  is absent, so a caller can thread this unconditionally.

  Errors are tagged by the caller's substrate, e.g.
  `{:error, {:docker, {:invalid_volume, reason}}}`, by matching on the reason
  this returns.

      iex> CrowdControl.Volume.normalize([volumes: [%{name: "w", target: "/w"}]], [])
      {:ok, [%{kind: :volume, source: "w", target: "/w", read_only: false}]}

      iex> CrowdControl.Volume.normalize([volumes: [%{target: "/w"}]], [])
      {:error, {:invalid_volume, %{target: "/w"}, :source_required}}

      iex> CrowdControl.Volume.normalize([volumes: [%{name: "w", target: "/f"}]], ["/f"])
      {:error, {:invalid_volume, %{name: "w", target: "/f"}, {:reserved_target, "/f"}}}
  """
  @spec normalize(keyword(), [String.t()]) :: {:ok, [normalized()]} | {:error, term()}
  def normalize(opts, reserved) when is_list(opts) and is_list(reserved) do
    case Keyword.get(opts, :volumes) do
      nil -> {:ok, []}
      [] -> {:ok, []}
      list when is_list(list) -> normalize_list(list, reserved)
      other -> {:error, {:invalid_volumes, other}}
    end
  end

  @doc """
  `normalize/2` or raise.

  For call sites downstream of a `provision/1` that already validated, where a
  bad mount means the validation was skipped rather than that a caller passed
  something wrong — a bug worth a readable crash instead of a `MatchError`.
  """
  @spec normalize!(keyword(), [String.t()]) :: [normalized()]
  def normalize!(opts, reserved) do
    case normalize(opts, reserved) do
      {:ok, mounts} -> mounts
      {:error, reason} -> raise ArgumentError, "invalid :volumes — #{inspect(reason)}"
    end
  end

  defp normalize_list(list, reserved) do
    Enum.reduce_while(list, {:ok, []}, fn spec, {:ok, acc} ->
      case normalize_one(spec, reserved, acc) do
        {:ok, mount} -> {:cont, {:ok, [mount | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp normalize_one(spec, reserved, acc) when is_map(spec) do
    with {:ok, kind, source} <- source(spec),
         {:ok, target} <- target(spec, reserved, acc) do
      {:ok,
       %{
         kind: kind,
         source: source,
         target: target,
         read_only: Map.get(spec, :read_only, false) == true
       }}
    else
      {:error, reason} -> {:error, {:invalid_volume, spec, reason}}
    end
  end

  defp normalize_one(spec, _reserved, _acc), do: {:error, {:invalid_volume, spec, :not_a_map}}

  defp source(spec) do
    case {Map.get(spec, :name), Map.get(spec, :host_path)} do
      {nil, nil} ->
        {:error, :source_required}

      {name, nil} when is_binary(name) and name != "" ->
        {:ok, :volume, name}

      {nil, path} when is_binary(path) ->
        # Relative host paths are the Docker CLI's shorthand, not the Engine
        # API's, and Kubernetes has no equivalent at all. Refusing beats each
        # substrate resolving it against a different working directory.
        if absolute?(path),
          do: {:ok, :host_path, path},
          else: {:error, {:host_path_not_absolute, path}}

      {_, _} ->
        {:error, :ambiguous_source}
    end
  end

  defp target(spec, reserved, acc) do
    case Map.get(spec, :target) do
      target when is_binary(target) ->
        cond do
          not absolute?(target) -> {:error, {:target_not_absolute, target}}
          collides?(target, reserved) -> {:error, {:reserved_target, target}}
          Enum.any?(acc, &(&1.target == target)) -> {:error, {:duplicate_target, target}}
          true -> {:ok, target}
        end

      other ->
        {:error, {:bad_target, other}}
    end
  end

  # A mount at the FIFO's directory hides the FIFO just as completely as one at
  # the FIFO itself, and both produce a sandbox that starts and then says
  # nothing. Compare on path segments so "/var/log/cc2" is not read as being
  # under "/var/log/cc".
  defp collides?(target, reserved) do
    segments = Path.split(target)

    Enum.any?(reserved, fn path ->
      reserved_segments = Path.split(path)
      prefix?(segments, reserved_segments) or prefix?(reserved_segments, segments)
    end)
  end

  defp prefix?(a, b), do: Enum.take(b, length(a)) == a

  defp absolute?(path), do: String.starts_with?(path, "/")
end
