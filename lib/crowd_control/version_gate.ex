defmodule CrowdControl.VersionGate do
  @moduledoc """
  Minimum server versions for the features a session asks for. Pure.

  A feature that needs a newer substrate than the one running fails *before*
  anything is created, with a typed error, rather than as a confusing
  half-built session later:

  | Feature | Needs | Why |
  |---|---|---|
  | `:pod_sidecars` | Kubernetes 1.29 | native sidecars (`initContainers` with `restartPolicy: Always`) |
  | `:prestop_sleep` | Kubernetes 1.30 | the log-shipper drain is a kubelet `preStop.sleep` |
  | `:service_networks` | Docker 25.0.5 | per-service internal networks: CVE-2024-29018 leaks DNS from internal networks before 25.0.5 / 26.0.0 |
  | `:egress_sidecars` | Docker 25.0.5 | an `egress: :allow` sidecar beside an internal network, same CVE |

  Versions are only looked up when a requested feature needs one —
  `components/1` says which — so a session that asks for none of these never
  makes the extra request.

  Kubernetes versions are `{major, minor}`, Docker versions
  `{major, minor, patch}`; both compare as tuples.
  """

  @type component :: :kubernetes | :docker
  @type version ::
          {non_neg_integer(), non_neg_integer()}
          | {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  @type feature :: :pod_sidecars | :prestop_sleep | :service_networks | :egress_sidecars

  @floors %{
    pod_sidecars: {:kubernetes, {1, 29}},
    prestop_sleep: {:kubernetes, {1, 30}},
    service_networks: {:docker, {25, 0, 5}},
    egress_sidecars: {:docker, {25, 0, 5}}
  }

  @doc """
  The minimum version per component that `features` require, highest floor
  wins.

      iex> CrowdControl.VersionGate.requirements([:pod_sidecars, :prestop_sleep])
      %{kubernetes: {1, 30}}

      iex> CrowdControl.VersionGate.requirements([])
      %{}
  """
  @spec requirements([feature()]) :: %{optional(component()) => version()}
  def requirements(features) do
    features
    |> Enum.uniq()
    |> Enum.map(&floor!/1)
    |> Enum.reduce(%{}, fn {component, need}, acc ->
      Map.update(acc, component, need, &max(&1, need))
    end)
  end

  @doc """
  The components whose server version must be fetched to check `features`.

      iex> CrowdControl.VersionGate.components([:egress_sidecars])
      [:docker]
  """
  @spec components([feature()]) :: [component()]
  def components(features), do: features |> requirements() |> Map.keys() |> Enum.sort()

  @doc """
  `:ok` when every component meets the floor `features` require, else the
  first shortfall, in component order.

  A required component missing from `versions` reports `have` as `:unknown`:
  a gate that could not see the version must not pass.

      iex> CrowdControl.VersionGate.check([:prestop_sleep], %{kubernetes: {1, 31}})
      :ok

      iex> CrowdControl.VersionGate.check([:prestop_sleep], %{kubernetes: {1, 29}})
      {:error, {:version, :kubernetes, {1, 29}, {1, 30}}}

      iex> CrowdControl.VersionGate.check([:egress_sidecars], %{})
      {:error, {:version, :docker, :unknown, {25, 0, 5}}}
  """
  @spec check([feature()], %{optional(component()) => version()}) ::
          :ok | {:error, {:version, component(), version() | :unknown, version()}}
  def check(features, versions) do
    features
    |> requirements()
    |> Enum.sort()
    |> Enum.find_value(:ok, fn {component, need} ->
      case Map.get(versions, component) do
        have when is_tuple(have) and have >= need -> nil
        have when is_tuple(have) -> {:error, {:version, component, have, need}}
        _ -> {:error, {:version, component, :unknown, need}}
      end
    end)
  end

  defp floor!(feature) do
    case Map.fetch(@floors, feature) do
      {:ok, floor} -> floor
      :error -> raise ArgumentError, "unknown version-gated feature: #{inspect(feature)}"
    end
  end
end
