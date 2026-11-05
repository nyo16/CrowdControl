defmodule CrowdControl.Backend.Kubernetes.Secrets do
  @moduledoc """
  A service's `env` as a per-session Secret, and the container `env` entries
  that read it through `valueFrom.secretKeyRef`. Pure.

  One Secret per service with a non-empty `env`, named
  `cc-<session_key>-<service>-env` and labelled `crowd_control.session`,
  `crowd_control.owner_hash`, `crowd_control.service` and
  `crowd_control.role=service-secret`, so `destroy/1` can derive the name and
  a reaper sweep can find an orphan by label. Each variable is one key, named
  after the variable, with its value in `data` (base64, so any bytes survive).

  The point is what is *not* in the Pod spec: no literal value, so `get pods`
  and `kubectl describe pod` show a reference and nothing else. That covers
  `:pod` sidecars, which live in the sandbox Pod's own spec, as well as
  `:separate` service Pods. The Secret itself is readable by whoever has `get`
  on `secrets` in the namespace, which is what Secret RBAC is for.
  """

  alias CrowdControl.Backend.Kubernetes

  @doc """
  The Secret name for `service`'s env in session `session_key`.

      iex> CrowdControl.Backend.Kubernetes.Secrets.secret_name("0123abcd", "browser")
      "cc-0123abcd-browser-env"
  """
  @spec secret_name(String.t(), String.t()) :: String.t()
  def secret_name(session_key, service), do: "cc-#{session_key}-#{service}-env"

  @doc """
  The Secret manifest for `service`'s `env` in the session `session`
  describes — anything carrying `:session_key`, `:owner` and `:namespace`,
  and optionally `:sweep_after_ms`, as for `Kubernetes.Files.manifest/3`.
  """
  @spec manifest(
          %{
            required(:session_key) => String.t(),
            required(:owner) => String.t() | nil,
            required(:namespace) => String.t(),
            optional(:sweep_after_ms) => non_neg_integer() | nil
          },
          String.t(),
          %{String.t() => String.t()}
        ) :: map()
  def manifest(
        %{session_key: session_key, owner: owner, namespace: namespace} = session,
        service,
        env
      ) do
    %{
      "apiVersion" => "v1",
      "kind" => "Secret",
      "type" => "Opaque",
      "metadata" => %{
        "name" => secret_name(session_key, service),
        "namespace" => namespace,
        "labels" => %{
          "crowd_control.session" => session_key,
          "crowd_control.owner_hash" => Kubernetes.owner_label(owner),
          "crowd_control.service" => service,
          "crowd_control.role" => "service-secret"
        },
        "annotations" => Kubernetes.object_annotations(session)
      },
      "data" => Map.new(env, fn {name, value} -> {name, Base.encode64(value)} end)
    }
  end

  @doc """
  The container `env` for `service`'s `env`: one `secretKeyRef` per
  variable, sorted, so a manifest is a function of its inputs; `nil` for an
  empty `env`.
  """
  @spec env(String.t(), String.t(), %{String.t() => String.t()}) :: [map()] | nil
  def env(_session_key, _service, env) when map_size(env) == 0, do: nil

  def env(session_key, service, env) do
    secret = secret_name(session_key, service)

    env
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn name ->
      %{
        "name" => name,
        "valueFrom" => %{"secretKeyRef" => %{"name" => secret, "key" => name}}
      }
    end)
  end
end
