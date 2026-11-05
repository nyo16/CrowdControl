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

  @doc "The kubeconfig file `kubeconfig/0` loads."
  @spec kubeconfig_path() :: String.t()
  def kubeconfig_path, do: System.get_env("CC_K8S_KUBECONFIG", Path.expand("~/.kube/config"))

  @doc "The loaded kubeconfig for `context/0`, for the backend's `:kubeconfig`."
  @spec kubeconfig(String.t()) :: Kubereq.Kubeconfig.t()
  def kubeconfig(path \\ kubeconfig_path()) do
    Kubereq.Kubeconfig.load({Kubereq.Kubeconfig.File, path: path, context: context(), !: true})
  end

  @doc """
  The `@moduletag skip:` and `@tag skip:` reasons for the live test module in
  `file` (pass `__ENV__.file`), worked out while it compiles — ExUnit has no
  runtime skip:

    * `:cluster` — why there is no cluster to run on at all (no kubeconfig,
      or no `context/0` in it), else `nil`;
    * `:policy` — why a check that needs NetworkPolicy enforcement cannot
      run: the cluster's reason, or the backend's enforcement probe saying
      "not enforced", else `nil`.

  Only the probe's own "not enforced" verdict is a skip. Any other probe
  failure — an image that will not pull, missing RBAC, a quota, a timeout —
  is a broken cluster, and raises: a deny check reported as skipped there
  would hide exactly the failure it exists to catch.

  Nothing runs unless this is a live run of `file`: `:k8s` is included
  (`--include k8s`, `--only k8s`), or a location filter names it
  (`mix test path/to/file.exs:LINE`, which includes the test however `:k8s`
  is configured). The probe provisions a `:deny_all` sandbox — the gate every
  policy-dependent check would pass through anyway — and the verdict is
  cached per cluster in `:persistent_term`, so the tests' own provisions
  reuse it.

  `opts` exist for this module's own unit test: `:configuration` (default
  `ExUnit.configuration/0`) and `:kubeconfig_path` (default
  `kubeconfig_path/0`).
  """
  @spec skip_reasons(String.t(), keyword()) :: %{
          cluster: String.t() | nil,
          policy: String.t() | nil
        }
  def skip_reasons(file, opts \\ []) do
    configuration = Keyword.get_lazy(opts, :configuration, &ExUnit.configuration/0)
    path = Keyword.get_lazy(opts, :kubeconfig_path, &kubeconfig_path/0)

    with true <- live_run?(file, configuration),
         {:ok, kubeconfig} <- load(path) do
      %{cluster: nil, policy: probe(kubeconfig)}
    else
      false -> %{cluster: nil, policy: nil}
      {:error, reason} -> %{cluster: reason, policy: reason}
    end
  end

  @doc false
  # Whether `configuration` (ExUnit's) runs `file`'s `:k8s` tests.
  @spec live_run?(String.t(), keyword()) :: boolean()
  def live_run?(file, configuration) do
    configuration
    |> Keyword.get(:include, [])
    |> Enum.any?(fn
      :k8s -> true
      {:k8s, _value} -> true
      {:location, {path, _lines}} -> names?(file, path)
      {:location, path} -> names?(file, path)
      _other -> false
    end)
  end

  # ExUnit's own test for a location filter: the filter's path is relative
  # to the working directory, the file's absolute.
  defp names?(file, path) when is_binary(path), do: String.ends_with?(file, path)
  defp names?(_file, _path), do: false

  defp load(path) do
    if File.exists?(path) do
      try do
        {:ok, kubeconfig(path)}
      rescue
        e ->
          {:error,
           "no usable kube context #{inspect(context())} in #{path}: #{Exception.message(e)}"}
      end
    else
      {:error, "no kubeconfig at #{path} (set CC_K8S_KUBECONFIG and CC_K8S_CONTEXT)"}
    end
  end

  defp probe(kubeconfig) do
    opts = [
      image: "busybox:1.36",
      kubeconfig: kubeconfig,
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
        raise "the NetworkPolicy enforcement gate could not run on context #{context()}: " <>
                "#{inspect(reason)}. This is a broken cluster (image pull, RBAC, quota or " <>
                "timeout), not one that ignores NetworkPolicy, so the deny checks are not " <>
                "skipped; fix the cluster or exclude :k8s"
    end
  end
end
