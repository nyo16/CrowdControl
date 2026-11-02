defmodule CrowdControl.Backend.Kubernetes.Files do
  @moduledoc """
  A service's `:files` as a per-session ConfigMap, and the volume and mounts
  that project it into the container read-only. Pure.

  One ConfigMap per service, named `cc-<session_key>-<service>-files` and
  labelled `crowd_control.session`, `crowd_control.owner_hash`,
  `crowd_control.service` and `crowd_control.role=service-config`, so
  `destroy/1` can derive the name and a reaper sweep can find an orphan by
  label.

  Each file becomes one key — `<index>-<basename>`, sanitised to the ConfigMap
  key alphabet, so two files with the same basename cannot collide — projected
  through `items` with its `mode` and mounted at its own absolute path with
  `subPath`. UTF-8 content goes in `data`; anything else in `binaryData`.

  Per-file ownership is not expressible here: projected files belong to root
  with the Pod's `fsGroup`, so `:uid`/`:gid` are ignored on Kubernetes.

  **Never credentials.** A ConfigMap is readable by anyone with `get` on the
  namespace; secrets go through an operator-managed Secret reference instead.
  See `CrowdControl.Service`.
  """

  alias CrowdControl.Backend.Kubernetes

  @doc """
  The ConfigMap name for `service` in session `session_key`.

      iex> CrowdControl.Backend.Kubernetes.Files.config_map_name("0123abcd", "proxy")
      "cc-0123abcd-proxy-files"
  """
  @spec config_map_name(String.t(), String.t()) :: String.t()
  def config_map_name(session_key, service), do: "cc-#{session_key}-#{service}-files"

  @doc "The Pod volume name the ConfigMap is attached under."
  @spec volume_name(String.t()) :: String.t()
  def volume_name(service), do: "cc-files-#{service}"

  @doc """
  The ConfigMap manifest for `service`'s `files` in the session `session`
  describes — anything carrying `:session_key`, `:owner` and `:namespace`,
  such as a `%CrowdControl.Backend.Kubernetes{}` handle. `files` are already
  validated by `CrowdControl.Service.validate_files/2`.
  """
  @spec manifest(
          %{session_key: String.t(), owner: String.t() | nil, namespace: String.t()},
          String.t(),
          [CrowdControl.Service.file()]
        ) :: map()
  def manifest(%{session_key: session_key, owner: owner, namespace: namespace}, service, files) do
    {data, binary_data} =
      files
      |> keyed()
      |> Enum.split_with(fn {_key, file} -> String.valid?(file.content) end)

    %{
      "apiVersion" => "v1",
      "kind" => "ConfigMap",
      "metadata" => %{
        "name" => config_map_name(session_key, service),
        "namespace" => namespace,
        "labels" => %{
          "crowd_control.session" => session_key,
          "crowd_control.owner_hash" => Kubernetes.owner_label(owner),
          "crowd_control.service" => service,
          "crowd_control.role" => "service-config"
        },
        "annotations" => %{"crowd_control.owner" => to_string(owner)}
      },
      "data" => Map.new(data, fn {key, file} -> {key, file.content} end),
      "binaryData" =>
        Map.new(binary_data, fn {key, file} -> {key, Base.encode64(file.content)} end)
    }
  end

  @doc """
  The Pod `volumes` entry: the ConfigMap, with one `items` projection per file
  carrying its `mode`.
  """
  @spec volume(String.t(), String.t(), [CrowdControl.Service.file()]) :: map()
  def volume(session_key, service, files) do
    %{
      "name" => volume_name(service),
      "configMap" => %{
        "name" => config_map_name(session_key, service),
        "items" =>
          Enum.map(keyed(files), fn {key, file} ->
            %{"key" => key, "path" => key, "mode" => file.mode}
          end)
      }
    }
  end

  @doc "The container `volumeMounts`: each file read-only at its own path, via `subPath`."
  @spec mounts(String.t(), [CrowdControl.Service.file()]) :: [map()]
  def mounts(service, files) do
    Enum.map(keyed(files), fn {key, file} ->
      %{
        "name" => volume_name(service),
        "mountPath" => file.path,
        "subPath" => key,
        "readOnly" => true
      }
    end)
  end

  @doc """
  The ConfigMap key for the file at `index` (0-based) and `path`.

      iex> CrowdControl.Backend.Kubernetes.Files.key(0, "/cfg/acl yaml")
      "0-acl_yaml"
  """
  @spec key(non_neg_integer(), String.t()) :: String.t()
  def key(index, path) do
    base = path |> Path.basename() |> String.replace(~r/[^-._a-zA-Z0-9]/, "_")
    String.slice("#{index}-#{base}", 0, 253)
  end

  defp keyed(files) do
    files
    |> Enum.with_index()
    |> Enum.map(fn {file, index} -> {key(index, file.path), file} end)
  end
end
