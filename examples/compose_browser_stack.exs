# The strict two-tier browser layout on Docker: a sandbox with no egress at all,
# a headless Chromium it drives from another container, and an allowlist proxy
# that only the browser can reach. Built from `CrowdControl.Preset.browser_stack/1`
# plus a Vector log shipper (`CrowdControl.Preset.LogShipper`).
#
#   mix run examples/compose_browser_stack.exs
#
#     sbx (internal)          brw (internal)          egress
#     sandbox ── browser ──── egress-proxy ─────────── internet (example.com only)
#        │                         │
#     cclog ── vector ── proxylog ─┘        (redacted transcript + proxy decisions)
#
# Needs Docker >= 25.0.5 and three local images, none of them published:
#
#   docker build --target sandbox-browser -t crowd_control/sandbox-browser:dev .
#   docker build --build-arg PLAYWRIGHT_VERSION=$(cat PLAYWRIGHT_VERSION) \
#     -t crowd_control/browser:dev examples/images/browser
#   docker build -t crowd_control/smokescreen:dev examples/images/smokescreen
#
# plus two public images, pulled by hand because the providers never pull
# (Vector by the digest `CrowdControl.Preset.LogShipper` pins):
#
#   docker pull timberio/vector:0.61.0-distroless-libc@sha256:1a3451978644d5cd4b99a0b28c990791e2f7e1efbea4184122f1c59a56448143
#   docker pull alpine/socat:1.8.1.3
#
# Two modes:
#
#   * **No API key (default).** The "agent" is a Node script standing in for
#     the CLI through the public `CrowdControl.Agent` behaviour, exactly like
#     examples/kubernetes_task.exs does with `sh`. It serves a page on
#     0.0.0.0:5173 and drives the browser over `PW_WS_ENDPOINT` -- the same
#     variable the preset hands the real CLI -- to load that page, an
#     allowlisted site and a denied one. Everything below the agent is what a
#     real session gets.
#   * **Claude Code.** Set ANTHROPIC_API_KEY *and* CC_API_PROXY_IMAGE. The
#     sandbox has no route to the API, so the CLI needs an API proxy named by
#     `:proxy_service`; none ships with this library (SECURITY.md, "Egress
#     proxy contract"). It must serve HTTP on 8080 and default to a non-root
#     user (or the `api-proxy` spec below needs a `user:`). That proxy is the one
#     egress service allowed on the sandbox's network; the browser's proxy
#     never is.
#
# While it runs, `docker logs -f <project>-vector` shows the shipped events:
# the transcript with secrets (and the `ccpw_` browser token the init line
# leaks) replaced by SHA-256 hex, and one `proxy_decision` per CONNECT.

secret =
  System.get_env("CC_SANDBOXD_SECRET") ||
    Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

Application.put_env(:crowd_control, :sandboxd_secret, secret)

# ---------------------------------------------------------------------------
# The stand-in agent. Node is what the sandbox-browser image has, and the
# Playwright client in it is the version in PLAYWRIGHT_VERSION, which the
# browser runs too (a different minor would get a 428 from the run-server).
# A bare require resolves through the image's NODE_PATH, as an agent's would.
# ---------------------------------------------------------------------------
defmodule BrowserAgent do
  @behaviour CrowdControl.Agent

  @script ~S"""
  const { chromium } = require('playwright');
  const os = require('node:os');
  const say = (o) => process.stdout.write(JSON.stringify(o) + '\n');

  // The app under test. Bound to 0.0.0.0: the browser reaches it as
  // http://sandbox:5173 across sbx, never through the proxy.
  require('node:http').createServer((_q, s) => {
    s.writeHead(200, { 'content-type': 'text/html' });
    s.end(`<title>served from ${os.hostname()}</title>`);
  }).listen(5173, '0.0.0.0');

  say({ type: 'system', subtype: 'init', session_id: os.hostname() });

  const visit = async (page, url) => {
    try {
      const r = await page.goto(url, { timeout: 30000 });
      return `${url} -> ${r.status()} "${await page.title()}"`;
    } catch (e) {
      return `${url} -> ${e.message.split('\n')[0]}`;
    }
  };

  require('node:readline').createInterface({ input: process.stdin }).on('line', async (line) => {
    const urls = line.match(/https?:\/\/[^\s"\\]+/g) || [];
    const browser = await chromium.connect(process.env.PW_WS_ENDPOINT);
    const page = await browser.newPage();
    const lines = [];
    for (const url of urls) lines.push(await visit(page, url));
    await browser.close();
    say({ type: 'result', subtype: 'success', result: lines.join('\n'), num_turns: 1 });
  });
  """

  # `env` carries PW_WS_ENDPOINT from the preset's sandbox overrides.
  @impl true
  def build_command(opts), do: {"node", ["-e", @script], opts[:env] || %{}}

  @impl true
  def init_frames(_opts), do: []

  @impl true
  def encode_prompt(prompt, _seq, _opts), do: CrowdControl.Protocol.encode_user_message(prompt)

  @impl true
  defdelegate decode_line(line), to: CrowdControl.Protocol
end

sandbox_image = System.get_env("CC_SANDBOX_IMAGE", "crowd_control/sandbox-browser:dev")
api_key = System.get_env("ANTHROPIC_API_KEY")
api_proxy_image = System.get_env("CC_API_PROXY_IMAGE")
claude? = api_key != nil and api_proxy_image != nil

{services, networks, overrides} =
  CrowdControl.Preset.browser_stack(
    substrate: :compose,
    proxy: [
      image: System.get_env("CC_PROXY_IMAGE", "crowd_control/smokescreen:dev"),
      allow_domains: ["example.com"],
      nc: true,
      # Shared with Vector, so the proxy's decisions are shipped too.
      log_volume: "proxylog"
    ],
    browser: [image: System.get_env("CC_BROWSER_IMAGE", "crowd_control/browser:dev")],
    # The browser bypasses the proxy for `sandbox` (the proxy would refuse a
    # private address).
    app_ports: [5173]
  )

# Reads the capture through a read-only mount of the volume the sandbox
# writes it to. The console sink keeps it on sbx with no egress; a real sink
# (`{:http, uri: ...}`, `{:loki, endpoint: ...}`) puts it on its own "log"
# network instead, which then needs declaring in `:networks`.
vector =
  CrowdControl.Preset.LogShipper.spec(
    sink: :console,
    capture_volume: "cclog",
    proxy_log_volume: "proxylog"
  )

# The sandbox-browser image's default entrypoint is the library's own iex; as a
# Compose sandbox it runs the sandboxd release the image also carries.
sandbox = %{
  name: "sandbox",
  image: sandbox_image,
  entrypoint: ["/opt/sandboxd/bin/sandboxd"],
  command: ["start"],
  volumes: [%{name: "cclog", target: "/var/log/cc"}]
}

api_proxy =
  if claude?,
    do: [%{name: "api-proxy", image: api_proxy_image, egress: :allow, port: 8080}],
    else: []

provider = [
  image: sandbox_image,
  services: [sandbox | services] ++ [vector | api_proxy],
  networks: networks,
  volumes: [%{name: "cclog"}, %{name: "proxylog"}],
  ready_timeout: 120_000,
  health_timeout: 120_000
]

provider = if claude?, do: Keyword.put(provider, :proxy_service, "api-proxy"), else: provider
backend = {CrowdControl.Backend.Sandboxd, provider: {CrowdControl.Provider.Compose, provider}}

{prompt, session} =
  if claude? do
    # The overrides carry the browser endpoint env, the inline Playwright MCP
    # config, strict_mcp_config and a system-prompt line. Merge your own
    # :env, :mcp_config and :extra_args into them rather than shadowing them.
    {"Serve a one-line HTML page on 0.0.0.0:5173 in the background, then use the browser " <>
       "to open http://sandbox:5173, https://example.com and https://wikipedia.org, and " <>
       "report each page's title or the error.",
     overrides ++ [api_key: api_key, backend: backend]}
  else
    {"http://sandbox:5173/ https://example.com/ https://wikipedia.org/",
     overrides ++ [agent: BrowserAgent, executable: "node", backend: backend]}
  end

IO.puts("starting the stack (#{if claude?, do: "Claude Code", else: "stand-in agent"})...\n")

case CrowdControl.run(prompt, session ++ [timeout: 300_000]) do
  {:result, "success", r} ->
    IO.puts(r["result"])

    IO.puts("""

    The sandbox page loaded straight across sbx, example.com went through the
    proxy, and anything off the allowlist is net::ERR_PROXY_AUTH_UNSUPPORTED
    (Smokescreen's 407): policy, not a fault.
    """)

  {:result, subtype, r} ->
    IO.puts("failed (#{subtype}): #{inspect(r["result"])}")

  {:error, reason} ->
    IO.puts("""
    the stack never came up: #{inspect(reason)}

    Usual causes: no Docker daemon on DOCKER_HOST, one of the images above was
    not built, or a Docker older than 25.0.5 (per-service networks need it).
    """)
end
