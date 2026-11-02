defmodule CrowdControl.Test.K8sLive do
  @moduledoc false
  # Cluster selection and the NetworkPolicy gate for kubernetes_browser_test.exs.
  #
  # The context is always named explicitly — `CC_K8S_CONTEXT`, default
  # `orbstack` — and loaded from `~/.kube/config` (or `CC_K8S_KUBECONFIG`)
  # without touching the file's `current-context`, so a test run can never
  # land on whatever cluster the shell happens to point at.

  alias CrowdControl.Backend.Kubernetes
  alias CrowdControl.Store

  @default_context "orbstack"

  @doc "The kube context the live tests run against."
  @spec context() :: String.t()
  def context, do: System.get_env("CC_K8S_CONTEXT", @default_context)

  @doc "The loaded kubeconfig for `context/0`, for the backend's `:kubeconfig`."
  @spec kubeconfig() :: Kubereq.Kubeconfig.t()
  def kubeconfig do
    path = System.get_env("CC_K8S_KUBECONFIG", Path.expand("~/.kube/config"))
    Kubereq.Kubeconfig.load({Kubereq.Kubeconfig.File, path: path, context: context(), !: true})
  end

  @doc """
  `nil` when the cluster enforces NetworkPolicy, else why it does not, as a
  `@tag skip:` reason.

  Runs the backend's own enforcement probe by provisioning a `:deny_all`
  sandbox — the gate every policy-dependent check would pass through anyway
  — and only when `:k8s` tests are included, since it is called while the
  test module compiles (ExUnit has no runtime skip). The verdict is cached
  per cluster in `:persistent_term`, so the tests' own provisions reuse it.
  """
  @spec policy_skip_reason() :: String.t() | nil
  def policy_skip_reason do
    if :k8s in Keyword.get(ExUnit.configuration(), :include, []), do: probe(), else: nil
  end

  defp probe do
    opts = [
      image: "busybox:1.36",
      kubeconfig: kubeconfig(),
      owner: "cc-netpol-gate",
      session_key: Store.new_key(),
      network: :deny_all,
      provision_timeout: 120_000,
      timeout: 30_000
    ]

    case Kubernetes.provision(opts) do
      {:ok, handle} ->
        Kubernetes.destroy(handle)
        nil

      {:error, {:k8s, :network_policy_not_enforced}} ->
        "the backend's NetworkPolicy enforcement probe failed on context #{context()} " <>
          "(its probe Pod reached the API server through a deny-all policy), so a deny " <>
          "check here could pass for reasons other than policy; run on a cluster whose " <>
          "CNI passes the probe"

      {:error, reason} ->
        "the NetworkPolicy enforcement probe failed on context #{context()}: #{inspect(reason)}"
    end
  end
end
