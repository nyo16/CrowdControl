// One headless Chromium, served as a Playwright launchServer endpoint on :3000
// and as `playwright mcp` on :8931 bound to that same browser.
//
// Environment:
//   PW_WS_TOKEN      required; the launchServer wsPath, so the endpoint is
//                    ws://browser:3000/<token>. Never logged.
//   PW_PROXY_SERVER  optional; e.g. http://proxy:4750. Every page the browser
//                    loads goes through it.
//   PW_PROXY_BYPASS  optional; Chromium bypass list, e.g. "sandbox".
//   MCP_ALLOWED_HOSTS  optional; comma-separated host:port values MCP accepts
//                    as the Host header, default browser:8931. Any other Host
//                    gets 403. A malformed value exits 2.
//
// "listening" is logged once both servers accept connections. If either the
// browser or the MCP server dies, this process exits non-zero so the session
// fails instead of half-running.

import { spawn } from 'node:child_process';
import { connect } from 'node:net';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { chromium } from 'playwright';

const WS_PORT = 3000;
const MCP_PORT = 8931;
const MCP_BIND_TIMEOUT_MS = 60_000;

const token = process.env.PW_WS_TOKEN;
if (!token || !/^[A-Za-z0-9_-]{16,}$/.test(token)) {
  console.error('browser-sidecar: PW_WS_TOKEN must be set to at least 16 URL-safe characters');
  process.exit(2);
}

// A DNS label sequence (or IPv4 address) and a port, e.g. web:8931.
const HOST_PORT = /^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?:([0-9]{1,5})$/;
const allowedHosts = process.env.MCP_ALLOWED_HOSTS ?? `browser:${MCP_PORT}`;
const validHostPort = (entry) => {
  const match = HOST_PORT.exec(entry);
  return match !== null && Number(match[2]) >= 1 && Number(match[2]) <= 65535;
};
if (!allowedHosts.split(',').every(validHostPort)) {
  console.error(
    `browser-sidecar: MCP_ALLOWED_HOSTS must be comma-separated host:port values, got ${JSON.stringify(allowedHosts)}`,
  );
  process.exit(2);
}

const proxyServer = process.env.PW_PROXY_SERVER;
const proxy = proxyServer
  ? { server: proxyServer, bypass: process.env.PW_PROXY_BYPASS || undefined }
  : undefined;

let stopping = false;
let mcp;

const server = await chromium.launchServer({
  host: '0.0.0.0',
  port: WS_PORT,
  wsPath: `/${token}`,
  headless: true,
  proxy,
  // WebRTC may otherwise send UDP around the proxy.
  args: ['--force-webrtc-ip-handling-policy=disable_non_proxied_udp'],
});

server.process().on('exit', (code, signal) => {
  if (stopping) return;
  console.error(`browser-sidecar: browser exited (code=${code}, signal=${signal})`);
  fail();
});

const require = createRequire(import.meta.url);
const playwrightCli = join(dirname(require.resolve('playwright/package.json')), 'cli.js');

mcp = spawn(
  process.execPath,
  [
    playwrightCli,
    'mcp',
    '--port', String(MCP_PORT),
    '--host', '0.0.0.0',
    '--allowed-hosts', allowedHosts,
    '--endpoint', `ws://127.0.0.1:${WS_PORT}/${token}`,
    '--isolated',
  ],
  // The working directory may be read-only; MCP writes its output files
  // relative to it.
  { cwd: tmpdir(), stdio: ['ignore', 'inherit', 'inherit'] },
);

mcp.on('exit', (code, signal) => {
  if (stopping) return;
  console.error(`browser-sidecar: playwright mcp exited (code=${code}, signal=${signal})`);
  fail();
});

mcp.on('error', (error) => {
  if (stopping) return;
  console.error(`browser-sidecar: playwright mcp failed to start: ${error.message}`);
  fail();
});

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => shutdown(0));
}

// launchServer resolves once :3000 is bound; MCP binds :8931 some time after
// spawn, so poll it before claiming both are up.
if (await mcpBound()) {
  console.error(`browser-sidecar: listening on :${WS_PORT} (ws) and :${MCP_PORT} (mcp)`);
} else if (!stopping) {
  console.error(`browser-sidecar: playwright mcp did not bind :${MCP_PORT} within ${MCP_BIND_TIMEOUT_MS} ms`);
  fail();
}

async function mcpBound() {
  const deadline = Date.now() + MCP_BIND_TIMEOUT_MS;
  while (!stopping && Date.now() < deadline) {
    const up = await new Promise((resolve) => {
      const socket = connect(MCP_PORT, '127.0.0.1', () => {
        socket.end();
        resolve(true);
      });
      socket.on('error', () => resolve(false));
    });
    if (up) return true;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  return false;
}

function fail() {
  shutdown(1);
}

async function shutdown(code) {
  if (stopping) return;
  stopping = true;
  if (mcp && mcp.exitCode === null && mcp.signalCode === null) mcp.kill('SIGTERM');
  try {
    await server.close();
  } catch {
    // Already gone.
  }
  process.exit(code);
}
