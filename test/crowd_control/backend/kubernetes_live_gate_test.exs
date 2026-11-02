defmodule CrowdControl.Backend.KubernetesLiveGateTest do
  # The gate kubernetes_browser_test.exs compiles its skips from (W-20):
  # hermetic, against kubeconfigs written here whose servers never answer.
  use ExUnit.Case, async: true

  alias CrowdControl.Backend.Kubernetes
  alias CrowdControl.Backend.Kubernetes.API
  alias CrowdControl.Test.K8sLive

  @moduletag :tmp_dir

  @file_path "/repo/test/crowd_control/backend/kubernetes_browser_test.exs"
  @k8s [include: [:k8s]]

  describe "when the gate runs at all" do
    test "only on a live run of the file: :k8s included, or a location filter naming it" do
      assert K8sLive.live_run?(@file_path, include: [:k8s])
      assert K8sLive.live_run?(@file_path, include: [k8s: "true"])

      # `mix test test/…/kubernetes_browser_test.exs:291` includes that test
      # whatever `:k8s` is configured to, so the gate must run for it too.
      location = "test/crowd_control/backend/kubernetes_browser_test.exs"
      assert K8sLive.live_run?(@file_path, include: [location: {location, 291}])
      assert K8sLive.live_run?(@file_path, include: [location: {location, [291, 300]}])
      assert K8sLive.live_run?(@file_path, include: [location: location])

      refute K8sLive.live_run?(@file_path, include: [location: {"test/other_test.exs", 3}])
      refute K8sLive.live_run?(@file_path, include: [])
      refute K8sLive.live_run?(@file_path, [])
    end

    test "not a live run: nothing is loaded or probed", %{tmp_dir: dir} do
      assert K8sLive.skip_reasons(@file_path,
               configuration: [include: []],
               kubeconfig_path: Path.join(dir, "absent")
             ) == %{cluster: nil, policy: nil}
    end
  end

  describe "what the gate reports" do
    test "no kubeconfig is a skip reason for the whole module, not a crash", %{tmp_dir: dir} do
      path = Path.join(dir, "absent")

      assert %{cluster: reason, policy: reason} =
               K8sLive.skip_reasons(@file_path, configuration: @k8s, kubeconfig_path: path)

      assert reason =~ "no kubeconfig at #{path}"
    end

    test "a kubeconfig without the context is a skip reason too", %{tmp_dir: dir} do
      path = write_kubeconfig(dir, "https://cc-gate.invalid", "some-other-context")

      assert %{cluster: reason, policy: reason} =
               K8sLive.skip_reasons(@file_path, configuration: @k8s, kubeconfig_path: path)

      assert reason =~ "no usable kube context"
    end

    test "the probe's \"not enforced\" verdict skips only the policy checks", %{tmp_dir: dir} do
      path = write_kubeconfig(dir, unique_server())

      # The verdict the probe caches for this cluster, as a run that measured
      # "not enforced" leaves it; no request is made.
      key = {Kubernetes, :netpol_enforced, API.cluster_url(kubeconfig: K8sLive.kubeconfig(path))}
      :persistent_term.put(key, false)
      on_exit(fn -> :persistent_term.erase(key) end)

      assert %{cluster: nil, policy: reason} =
               K8sLive.skip_reasons(@file_path, configuration: @k8s, kubeconfig_path: path)

      assert reason =~ "enforcement probe failed"
    end

    test "any other probe failure is a broken cluster, and raises", %{tmp_dir: dir} do
      path = write_kubeconfig(dir, unique_server())

      assert_raise RuntimeError, ~r/broken cluster/, fn ->
        K8sLive.skip_reasons(@file_path, configuration: @k8s, kubeconfig_path: path)
      end
    end
  end

  # A server under `.invalid` (RFC 2606): it never resolves, so nothing is
  # ever dialled, and the probe verdict cache is this test's alone.
  defp unique_server, do: "https://cc-gate-#{System.unique_integer([:positive])}.invalid"

  defp write_kubeconfig(dir, server, context \\ K8sLive.context()) do
    path = Path.join(dir, "kubeconfig-#{System.unique_integer([:positive])}")

    File.write!(path, """
    apiVersion: v1
    kind: Config
    clusters:
      - name: gate
        cluster:
          server: #{server}
    users:
      - name: gate
        user: {}
    contexts:
      - name: #{context}
        context:
          cluster: gate
          user: gate
          namespace: default
    current-context: #{context}
    """)

    path
  end
end
