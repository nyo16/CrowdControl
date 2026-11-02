# The strict two-tier browser layout on Kubernetes: the sandbox Pod, a browser
# Pod and an allowlist-proxy Pod, each fenced by its own NetworkPolicy, built
# from `CrowdControl.Preset.browser_stack/1`.
#
#   CC_K8S_CONTEXT=my-cluster mix run examples/kubernetes_browser_stack.exs
#
#     sandbox Pod ──(sbx)── browser Pod ──(brw)── egress-proxy Pod ── internet
#     deny-all + named allows        no egress          443 only, allowlist
#
# Nothing resolves through kube-dns: every Pod gets `hostAliases` mapping its
# peers' names to their Service ClusterIPs, so `ws://browser:3000/...` and
# `http://sandbox:5173` mean what they mean on Compose.
#
# Needs Kubernetes >= 1.30, the optional `{:kubereq, "~> 0.4.5"}` dependency,
# and the same three images as examples/compose_browser_stack.exs (build
# commands there) where the nodes can pull them -- a local cluster sharing the
# Docker image store, as OrbStack does, needs no registry. No API key: the
# "agent" is a Node stand-in for the CLI, as in that example.
#
# Options, all environment variables:
#
#   * CC_K8S_CONTEXT -- the kubeconfig context, named explicitly; without it
#     the kubeconfig's current context is used.
#   * CC_K8S_NAMESPACE -- default: the context's namespace.
#   * CC_K8S_NETWORK_PROBE=false -- skip the enforcement probe. A `:separate`
#     service always runs it, and on a cluster whose CNI does not pass it the
#     provision is refused with {:k8s, :network_policy_not_enforced}: the
#     NetworkPolicies are the boundary here, and the backend will not report
#     one it cannot prove. Turn it off only on a cluster you know enforces
#     (OrbStack enforces pod-to-pod and internet policies but not the API
#     server path the probe tests) or for a throwaway demo.
#   * CC_K8S_AGGREGATOR=10.96.12.7:6000 -- also run a Vector log shipper as a
#     native sidecar in the sandbox Pod, shipping the redacted transcript to
#     the Vector aggregator at that address. A `:pod` sidecar shares the
#     sandbox's network namespace, so an in-cluster aggregator the sandbox's
#     policy names is the only sink allowed; it holds the real sink's
#     credentials.

defmodule BrowserAgent do
  @behaviour CrowdControl.Agent

  # A ClusterIP forwards only once kube-proxy has programmed the Service's
  # endpoints, which can trail Pod readiness by a few seconds, so the
  # stand-in retries a refused connection -- as a real agent would.
  @script ~S"""
  const { chromium } = require('/usr/lib/node_modules/playwright');
  const os = require('node:os');
  const say = (o) => process.stdout.write(JSON.stringify(o) + '\n');
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  require('node:http').createServer((_q, s) => {
    s.writeHead(200, { 'content-type': 'text/html' });
    s.end(`<title>served from ${os.hostname()}</title>`);
  }).listen(5173, '0.0.0.0');

  say({ type: 'system', subtype: 'init', session_id: os.hostname() });

  const retry = async (f) => {
    for (let i = 0; ; i++) {
      try { return await f(); } catch (e) {
        if (i >= 15 || !/ECONNREFUSED|ERR_CONNECTION_REFUSED/.test(e.message)) throw e;
        await sleep(1000);
      }
    }
  };

  const visit = async (page, url) => {
    try {
      const r = await retry(() => page.goto(url, { timeout: 30000 }));
      return `${url} -> ${r.status()} "${await page.title()}"`;
    } catch (e) {
      return `${url} -> ${e.message.split('\n')[0]}`;
    }
  };

  require('node:readline').createInterface({ input: process.stdin }).on('line', async (line) => {
    const urls = line.match(/https?:\/\/[^\s"\\]+/g) || [];
    const browser = await retry(() => chromium.connect(process.env.PW_WS_ENDPOINT));
    const page = await browser.newPage();
    const lines = [];
    for (const url of urls) lines.push(await visit(page, url));
    await browser.close();
    say({ type: 'result', subtype: 'success', result: lines.join('\n'), num_turns: 1 });
  });
  """

  @impl true
  def build_command(opts), do: {"node", ["-e", @script], opts[:env] || %{}}

  @impl true
  def init_frames(_opts), do: []

  @impl true
  def encode_prompt(prompt, _seq, _opts), do: CrowdControl.Protocol.encode_user_message(prompt)

  @impl true
  defdelegate decode_line(line), to: CrowdControl.Protocol
end

owner = "cc-example-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"

{services, [], overrides} =
  CrowdControl.Preset.browser_stack(
    substrate: :kubernetes,
    proxy: [
      image: System.get_env("CC_PROXY_IMAGE", "crowd_control/smokescreen:dev"),
      allow_domains: ["example.com"]
    ],
    browser: [image: System.get_env("CC_BROWSER_IMAGE", "crowd_control/browser:dev")],
    # Adds `sandbox_ports: [5173]` to the overrides: a ClusterIP Service for
    # the sandbox and a policy edge admitting the browser on that port only.
    app_ports: [5173]
  )

# Where it fits: a :pod Vector sidecar reading the capture emptyDir read-only.
shipper =
  case System.get_env("CC_K8S_AGGREGATOR") do
    nil ->
      []

    address ->
      [ip | _] = String.split(address, ":")

      CrowdControl.Preset.LogShipper.services(
        placement: :pod,
        sink: {:vector, address: address},
        aggregator: %{ip_block: "#{ip}/32"}
      )
  end

backend =
  [
    image: System.get_env("CC_SANDBOX_IMAGE", "crowd_control/sandbox-browser:dev"),
    owner: owner,
    # The sandbox's own deny-all, plus named allows to the browser (and the
    # aggregator) derived from the services' networks. Required: :services
    # never infer a posture.
    network: :deny_all,
    network_probe: System.get_env("CC_K8S_NETWORK_PROBE") != "false",
    services: services ++ shipper,
    provision_timeout: 300_000,
    timeout: 60_000,
    exec_timeout: 60_000
  ]
  |> then(fn opts ->
    case System.get_env("CC_K8S_CONTEXT") do
      nil ->
        opts

      context ->
        path = System.get_env("KUBECONFIG", Path.expand("~/.kube/config"))
        Keyword.put(opts, :kubeconfig, {Kubereq.Kubeconfig.File, path: path, context: context})
    end
  end)
  |> then(fn opts ->
    case System.get_env("CC_K8S_NAMESPACE") do
      nil -> opts
      ns -> Keyword.put(opts, :namespace, ns)
    end
  end)

IO.puts("provisioning sandbox, browser and proxy Pods (owner #{owner})...\n")

# The overrides carry PW_WS_ENDPOINT (in :env), the Playwright MCP config,
# and :sandbox_ports, which reaches the backend because session options are
# merged into its configuration.
result =
  CrowdControl.run(
    "http://sandbox:5173/ https://example.com/ https://wikipedia.org/",
    overrides ++
      [
        agent: BrowserAgent,
        executable: "node",
        backend: {CrowdControl.Backend.Kubernetes, backend},
        timeout: 600_000
      ]
  )

case result do
  {:result, "success", r} ->
    IO.puts(r["result"])

  {:result, subtype, r} ->
    IO.puts("failed (#{subtype}): #{inspect(r["result"])}")

  {:error, reason} ->
    IO.puts("""
    the stack never came up: #{inspect(reason)}

    {:k8s, :network_policy_not_enforced} means the enforcement probe did not
    pass on this cluster; see CC_K8S_NETWORK_PROBE above before turning it off.
    """)
end

# Verified, not assumed. list_live/1 reports sandboxes only -- never the
# browser or proxy Pods, which carry the same owner and session labels -- and
# destroy/1 took every Pod, Service, NetworkPolicy and ConfigMap with it.
{:ok, live} = CrowdControl.Backend.Kubernetes.list_live(Keyword.take(backend, [:owner, :kubeconfig, :namespace]))
IO.puts("\nsandboxes still live for #{owner}: #{length(live)}")
