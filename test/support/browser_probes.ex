defmodule CrowdControl.Test.BrowserProbes do
  @moduledoc false
  # Node scripts the live browser-stack tests (compose_browser_test.exs,
  # kubernetes_browser_test.exs) run inside the stack, from the container
  # whose posture each one is about. Every script takes its inputs as argv
  # (`node -e <script> <args...>`, so `process.argv.slice(1)`) and prints one
  # line: the sandbox Pod's exec has no env parameter, so nothing here reads
  # the environment.

  @playwright_version_file Path.expand("../../PLAYWRIGHT_VERSION", __DIR__)
  @external_resource @playwright_version_file
  @playwright_version @playwright_version_file |> File.read!() |> String.trim()

  @doc "The single Playwright pin, from the repository's `PLAYWRIGHT_VERSION` file."
  def playwright_version, do: @playwright_version

  @doc "`[kind, host, port]` -> `REACHABLE` | `BLOCKED` (tcp), `RESOLVES` | `NO-DNS` (dns)."
  def probe,
    do: ~S"""
    const net = require('node:net');
    const dns = require('node:dns').promises;
    const [kind, host, port] = process.argv.slice(1);
    const connect = () => new Promise((resolve) => {
      const s = net.connect({ host, port: Number(port), timeout: 3000 });
      s.on('connect', () => { s.destroy(); resolve('REACHABLE'); });
      s.on('timeout', () => { s.destroy(); resolve('BLOCKED'); });
      s.on('error', () => resolve('BLOCKED'));
    });
    const lookup = () => dns.lookup(host).then(() => 'RESOLVES', () => 'NO-DNS');
    (kind === 'dns' ? lookup() : connect()).then((r) => console.log(r));
    """

  @doc "`[port, marker]`: the agent's dev server, on 0.0.0.0 as the system prompt says."
  def dev_server,
    do: ~S"""
    const [port, marker] = process.argv.slice(1);
    require('node:http').createServer((_q, s) => {
      s.writeHead(200, { 'content-type': 'text/html' });
      s.end(`<html><head><title>cc-dev</title></head><body>${marker}</body></html>`);
    }).listen(Number(port), '0.0.0.0');
    """

  @doc """
  `[port, log]`: a STUN stand-in that logs every datagram as
  `<source> <bytes>` and touches `<log>.ready` once bound.
  """
  def udp_listener,
    do: ~S"""
    const fs = require('node:fs');
    const [port, log] = process.argv.slice(1);
    const s = require('node:dgram').createSocket('udp4');
    s.on('message', (m, r) => fs.appendFileSync(log, `${r.address} ${m.length}\n`));
    s.bind(Number(port), '0.0.0.0', () => fs.writeFileSync(`${log}.ready`, ''));
    """

  @doc "`[host, port]`: one 7-byte datagram, the control for the WebRTC check."
  def udp_send,
    do: ~S"""
    const [host, port] = process.argv.slice(1);
    const s = require('node:dgram').createSocket('udp4');
    s.send(Buffer.from('control'), Number(port), host, () => s.close());
    """

  @doc """
  `[ws_endpoint, app_url, stun_ip, stun_port]`: a client at the pinned
  Playwright version, resolved by a bare `require` through the image's
  `NODE_PATH`, as an agent's `chromium.connect` script would drive the
  browser. Prints a JSON object: `app`, `allowed` (example.com), `denied`
  (wikipedia.org) as `{status, title, body}` or `{error}`, and the ICE
  `candidates` a page gathered against a STUN server at `stun_ip`; or
  `{fatal}`.
  """
  def client,
    do: ~S"""
    const { chromium } = require('playwright');
    const [endpoint, app, stunIp, stunPort] = process.argv.slice(1);
    (async () => {
      const out = {};
      const browser = await chromium.connect(endpoint);
      out.version = browser.version();
      const page = await browser.newPage();
      const visit = async (url) => {
        try {
          const r = await page.goto(url, { timeout: 30000 });
          return { status: r.status(), title: await page.title(),
                   body: ((await page.textContent('body')) || '').slice(0, 200) };
        } catch (e) {
          return { error: e.message.split('\n')[0] };
        }
      };
      out.app = await visit(app);
      out.candidates = await page.evaluate(async ([ip, port]) => {
        const pc = new RTCPeerConnection({ iceServers: [{ urls: `stun:${ip}:${port}` }] });
        const found = [];
        pc.onicecandidate = (e) => { if (e.candidate) found.push(e.candidate.candidate); };
        pc.createDataChannel('leak');
        await pc.setLocalDescription(await pc.createOffer());
        await new Promise((done) => {
          const t = setTimeout(done, 8000);
          pc.onicegatheringstatechange = () => {
            if (pc.iceGatheringState === 'complete') { clearTimeout(t); done(); }
          };
        });
        pc.close();
        return found;
      }, [stunIp, stunPort]);
      out.allowed = await visit('https://example.com/');
      out.denied = await visit('https://wikipedia.org/');
      await browser.close();
      console.log(JSON.stringify(out));
    })().catch((e) => console.log(JSON.stringify({ fatal: e.message.split('\n')[0] })));
    """

  @doc """
  `[host, port, path, user_agent]`: a raw WebSocket upgrade, printing the
  status. Playwright's run-server compares the client version in the
  User-Agent against its own.
  """
  def ws_upgrade,
    do: ~S"""
    const [host, port, path, ua] = process.argv.slice(1);
    const req = require('node:http').request({ host, port: Number(port), path, headers: {
      Connection: 'Upgrade', Upgrade: 'websocket', 'Sec-WebSocket-Version': '13',
      'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ==', 'User-Agent': ua } });
    req.on('upgrade', (res, socket) => { console.log(res.statusCode); socket.destroy(); });
    req.on('response', (res) => { console.log(res.statusCode); res.resume(); });
    req.on('error', (e) => console.log('ERROR ' + e.message));
    req.setTimeout(10000, () => { console.log('TIMEOUT'); req.destroy(); });
    req.end();
    """

  @doc """
  `[host, port, host_header]`: MCP `initialize`, printing `{status, body}`.
  The 200 answer is an event stream that may stay open, so the first
  `serverInfo` ends it.
  """
  def mcp_initialize,
    do: ~S"""
    const [host, port, hostHeader] = process.argv.slice(1);
    const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {
      protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'cc-test', version: '0' } } });
    const done = (status, data) => { console.log(JSON.stringify({ status, body: data })); process.exit(0); };
    const req = require('node:http').request({ host, port: Number(port), path: '/mcp', method: 'POST',
      headers: { Host: hostHeader, 'Content-Type': 'application/json',
                 Accept: 'application/json, text/event-stream', 'Content-Length': Buffer.byteLength(body) } },
      (res) => {
        let data = '';
        res.on('data', (c) => { data += c; if (data.includes('serverInfo')) done(res.statusCode, data); });
        res.on('end', () => done(res.statusCode, data));
      });
    req.on('error', (e) => done(0, e.message));
    req.setTimeout(10000, () => done(0, 'TIMEOUT'));
    req.end(body);
    """

  @doc """
  The stand-in CLI, run through the backend so its stdout lands in the
  capture. The first line leaks the browser endpoint (and with it the
  `ccpw_` token), as a careless agent would; every later stdin line is
  echoed back verbatim.
  """
  def fake_cli,
    do: ~S"""
    printf '{"type":"system","subtype":"init","endpoint":"%s"}\n' "$PW_WS_ENDPOINT"
    while IFS= read -r line; do printf '%s\n' "$line"; done
    """

  @doc "A User-Agent claiming Playwright `version`."
  def user_agent(version), do: "Playwright/#{version} (arm64; ubuntu 24.04) node/22.23"
end
