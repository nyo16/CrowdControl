# Security Policy

## Supported Versions

Only the latest released minor version receives security fixes.

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |
| < 0.1   | :x:                |

## Reporting a Vulnerability

**Please do not open public GitHub issues for security reports.**

Email vulnerability reports to **niko@hackthebox.eu** with:

- A description of the issue and the impact
- Steps to reproduce (proof of concept where possible)
- The version of `crowd_control` affected
- Any suggested remediation

You will receive an acknowledgement within 5 business days. We aim to
release a fix within 90 days of acknowledgement and will coordinate
disclosure with you.

## Scope

In scope:

- Shell / argument / environment injection through `CrowdControl.CLI`
  and `CrowdControl.Session` (env file generation, `sanitize_path!/1`,
  `validate_env!/1`, `CrowdControl.Backend.Shell.escape/1`).
- Sandbox escape or credential disclosure through
  `CrowdControl.Backend.Docker` (container config, exec command
  construction, environment injection).
- `CrowdControl.Reaper` destroying sandboxes it does not own.
- Information disclosure through temp files, logs, or process listings.
- Denial of service against the session supervisor or individual sessions
  (resource exhaustion, hang vectors).
- Container hardening regressions in the provided `Dockerfile` and
  `docker-compose.yml`.

Out of scope:

- Vulnerabilities in the upstream `claude` / `opencode` CLIs.
- Vulnerabilities in `net_runner` (report upstream).
- Issues that require the attacker to already have local code-execution
  on the host where the library runs.

## Hardening Notes

See [`README.md`](README.md) and [`CHANGELOG.md`](CHANGELOG.md) for the
current set of hardening measures (API-key env file with `0600`
permissions in a per-session `0700` subdir, non-root Docker user, dropped
Linux capabilities, read-only root filesystem with tmpfs).

## Remote sandbox backends

`CrowdControl.Backend.Docker` runs a CLI inside a container. Two properties
are load-bearing and are asserted by the test suite rather than assumed.

**Secrets never enter argv.** Environment variables reach the CLI through
the Docker exec API's `Env` array. They are deliberately not interpolated
into the `sh -c` command string as `export KEY=...`, which would place every
secret in the shell's argv — readable by `ps` *inside* the container, where
model-driven code runs, and retrievable afterwards from
`GET /exec/{id}/json`. This is the remote counterpart of the local env-file
indirection. `test/crowd_control/backend/docker_test.exs` greps the
container's own `ps` output to enforce it.

**Prompts cross an `sh -c` boundary.** `send_prompt/2` content is written to
the container's FIFO via `printf %s <escaped> >> <fifo>`, quoted with the
same `CrowdControl.Backend.Shell.escape/1` used for local env values. There
is deliberately one escaper, not two. A test fires `$(touch /tmp/pwned)`
through a prompt and asserts the file is never created.

**The reaper only destroys what it owns.** Every container carries a
`crowd_control.owner` label (`config :crowd_control, :owner_id`, or `:owner` in
the backend config, defaulting to the node name). Listings filter on it
daemon-side, *and* the reaper re-checks the handle's owner locally before
destroying — destruction is irreversible, so it does not rest on a single
filter. A failed listing is treated as *unknown*, never as "nothing is live" —
the latter would delete every running sandbox.

The owner a session records must match the label its sandbox carries. If those
two can diverge, the reaper finds live sandboxes with no matching record and
destroys all of them as orphans.

**Sandbox containers are hardened by default.** `CapDrop: ALL`,
`no-new-privileges`, and `PidsLimit: 512` are applied unless overridden. The
PID ceiling matters independently of `:memory` and `:cpus`, neither of which
bounds process count — a fork bomb in model output would otherwise exhaust the
host. `:user` and `:readonly_rootfs` are opt-in because they break images that
expect root or write outside the tmpfs mounts; **enable both where your image
supports it.**

**Credentials are never persisted.** `CrowdControl.Store` records can outlive
the VM on disk, so `:api_key`, `:session_token`, and `:env` are stripped from
both the session opts and the backend handle before anything is written.
Nothing about reattaching needs them — the sandbox already holds the
environment it was started with. `Store.DETS` additionally restricts its file
to `0600` inside a `0700` directory.

## Egress proxy contract

**No proxy ships with this library.** `CrowdControl.Backend.Docker` provides
the wiring (`:proxy_url`, `:session_token`) and this section specifies what a
conforming proxy must do. Operating one is the caller's responsibility.

When `:proxy_url` is set, the backend rewrites the container's environment:

    ANTHROPIC_BASE_URL = <proxy_url>
    ANTHROPIC_API_KEY  = <session_token>

and **removes** any real `:api_key` rather than merely overriding it. Leaving
a working provider credential inside a sandbox that is supposed to reach only
the proxy would defeat the entire isolation argument; that silent
double-injection is asserted against directly in the test suite.

A conforming proxy MUST:

1. **Inject the real key.** The sandbox never holds a provider credential.
   The proxy maps an opaque per-session token to the real key and attaches it
   server-side.
2. **Enforce a per-session budget ceiling.** Token spend is attributable to
   the session token, and requests are refused once the ceiling is hit. A
   compromised sandbox must not be able to spend without bound.
3. **Enforce a model allowlist.** Reject any model not permitted for that
   session, so a sandbox cannot escalate to a more expensive model.
4. **Audit every request.** Log session token, model, token counts, and
   timestamp for the full request set — this is the only record of what a
   sandbox did, since the sandbox itself is untrusted.

It SHOULD also rate-limit per session and expire session tokens on session
end; neither is handled by this library.

### Network mode is the boundary

`:network_mode` defaults to `"none"`, meaning a provisioned sandbox has no
network at all. **Widening it is the moment the isolation boundary gets
weaker.** To reach a proxy, attach the container to a named network that
routes *only* to that proxy:

    config = [
      image: "my-cli:latest",
      network_mode: "cc-egress",        # reaches the proxy and nothing else
      proxy_url: "http://egress-proxy.internal:8080",
      session_token: per_session_token
    ]

Never use `bridge` for this. `bridge` grants general outbound access, which
makes the proxy advisory rather than enforcing — a sandbox can simply route
around it, and every guarantee above becomes unverifiable.

**This is enforced, not just advised.** Setting `:proxy_url` or `:api_url`
without an explicit `:network_mode` returns
`{:error, {:docker, :network_mode_required}}`. The backend will not choose a
network mode on your behalf in the one scenario where choosing wrong silently
removes the boundary.

### Not handled here

Provider rate-limit and quota handling belongs with the proxy and is out of
scope for this library. So is workspace push/pull: the optional
`push_workspace/2` and `pull_artifacts/2` callbacks exist in the behaviour
but ship with no implementation.
