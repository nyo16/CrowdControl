defmodule CrowdControl.Backend.Kubernetes.Drain do
  @moduledoc """
  Teardown budget for Pods that carry a drained sidecar. Pure.

  `destroy/1` deletes a bare sandbox Pod with `gracePeriodSeconds: 0`: it holds
  nothing worth flushing. A log shipper in the Pod changes that — SIGKILL
  mid-flush loses the transcript's tail — so a service with `drain:` set (see
  `CrowdControl.Service`) gets, all derived from the same two numbers:

    * a `preStop: {sleep: {seconds: drain}}` on the sidecar, so its file source
      reaches EOF before SIGTERM (kubelet-executed, Kubernetes 1.30+, gated by
      `CrowdControl.VersionGate`'s `:prestop_sleep`);
    * the Pod's `terminationGracePeriodSeconds`;
    * the `gracePeriodSeconds` the delete passes.

  Each is `drain + shutdown_limit + 5`, the margin letting the shipper exit on
  its own graceful-shutdown limit before the kubelet's SIGKILL. With several
  drained services the largest budget wins. With none, the grace is `0` and the
  Pod gets no `terminationGracePeriodSeconds` at all.
  """

  alias CrowdControl.Service

  @doc """
  The `gracePeriodSeconds` for deleting a Pod running `services`: `0` unless
  one of them is drained.

      iex> drained = %CrowdControl.Service{name: "vector", drain: 3_000, shutdown_limit: 20}
      iex> CrowdControl.Backend.Kubernetes.Drain.grace_seconds([drained])
      28

      iex> CrowdControl.Backend.Kubernetes.Drain.grace_seconds([%CrowdControl.Service{name: "b"}])
      0
  """
  @spec grace_seconds([Service.t()]) :: non_neg_integer()
  def grace_seconds(services) do
    services
    |> Enum.filter(&Service.drained?/1)
    |> Enum.map(&budget/1)
    |> Enum.max(fn -> 0 end)
  end

  @doc """
  The Pod's `terminationGracePeriodSeconds`, or `nil` when nothing is drained
  (the caller leaves the field unset and the Pod keeps the cluster default).
  """
  @spec termination_grace_period([Service.t()]) :: pos_integer() | nil
  def termination_grace_period(services) do
    case grace_seconds(services) do
      0 -> nil
      grace -> grace
    end
  end

  @doc """
  The container `lifecycle` for one service: a `preStop` sleep of the drain
  wait when it is drained, else `nil`.

      iex> svc = %CrowdControl.Service{name: "vector", drain: 2_500, shutdown_limit: 20}
      iex> CrowdControl.Backend.Kubernetes.Drain.lifecycle(svc)
      %{"preStop" => %{"sleep" => %{"seconds" => 3}}}
  """
  @spec lifecycle(Service.t()) :: map() | nil
  def lifecycle(%Service{} = service) do
    if Service.drained?(service) do
      %{"preStop" => %{"sleep" => %{"seconds" => Service.drain_seconds(service)}}}
    end
  end

  @doc """
  The `CrowdControl.VersionGate` features `services` need for draining:
  `[:prestop_sleep]` when any is drained, else `[]`.
  """
  @spec version_features([Service.t()]) :: [CrowdControl.VersionGate.feature()]
  def version_features(services) do
    if Enum.any?(services, &Service.drained?/1), do: [:prestop_sleep], else: []
  end

  defp budget(service), do: Service.drain_seconds(service) + Service.stop_timeout(service)
end
