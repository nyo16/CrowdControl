# Changelog

## Unreleased

### Added

- **`examples/kubernetes_task.exs`** — fan out N sandboxes as concurrent tasks,
  one Pod each, then ask the API server whether anything leaked. It needs no API
  key and no custom image: the CLI inside each Pod is a `sh` loop wired in
  through the public `CrowdControl.Agent` behaviour, so every layer below the
  agent is exactly what a real CLI gets. The README's Kubernetes and GCE
  sections now link their runnable examples, which nothing did before.

## 0.1.1 — 2026-08-31

Two defects in 0.1.0, both found by smoke-testing the *published* release rather
than the repo — neither was reachable from inside this checkout.

### Fixed

- **The GCE startup script now follows redirects when fetching the agent
  tarball.** `curl -fsS` without `-L` treats a redirect as a failure, and a
  GitHub release asset — which is exactly what this project's own `sandboxd-v*`
  channel publishes, and what the README and `examples/gce_spot_vm.exs` tell you
  to pass as `:sandboxd_url` — answers `302` and redirects to
  `objects.githubusercontent.com`. So the documented URL could never have worked:
  the bootstrap died, and `acquire/1` surfaced it as a health timeout on a VM that
  was already billing.

  Measured both ways against real GCP: the integration suite fails 1/3 with the
  published URL before the fix and passes 3/3 after it. Following a redirect to
  another host is safe here specifically because `:sandboxd_sha256` is mandatory
  and never skipped — a redirect anywhere else produces a mismatch and the agent
  is never installed. The metadata-server fetch deliberately does **not** follow
  redirects, and a test now pins both halves.
- **No compile warning for projects that do not use the Kubernetes backend.**
  Kubereq.Connect was missing from `CrowdControl.Backend.Kubernetes.API`'s
  `@compile {:no_warn_undefined, …}` list, so every consumer without the optional
  `:kubereq` dependency — most of them — saw
  `Kubereq.Connect.send_frame/2 is undefined` while compiling. Invisible in this
  repo, where kubereq is always present; caught by installing 0.1.0 into a fresh
  project.

## 0.1.0 — 2026-08-31

First published release. The version matches `@version` in `mix.exs`; if you tag
something other than `v0.1.0`, change this heading to match, because CI rewrites
the version in `mix.exs` from the tag but not this file.

### Breaking

- **Licensed under Apache-2.0**, replacing MIT. Apache-2.0 adds an express
  patent grant and an attribution/NOTICE requirement. Nothing was ever
  published under MIT — the package has not been released to Hex — so no
  existing user's terms change.

- **`CrowdControl.Session` state no longer exposes `:proc`, `:env_dir`, or
  `:env_file`.** Everything transport-specific moved behind the new
  `CrowdControl.Backend` behaviour. The public API (`start_link/1`,
  `send_prompt/2`, `subscribe/1`, `get_messages/1`, `get_status/1`, `stop/1`)
  and every broadcast message shape are unchanged, but code reaching into
  session state via `:sys.get_state/1` breaks:

  ```elixir
  # before
  :sys.get_state(pid).env_dir

  # after — env_dir belongs to the local backend's handle
  :sys.get_state(pid).backend_state.env_dir
  ```

  The struct gains `:backend`, `:backend_state`, `:store_key`, `:byte_offset`,
  and `:persist?`.

- **`CrowdControl.Session` is now `restart: :transient`, was `:temporary`.**
  `:temporary` is correct when the OS process dies with the GenServer and
  backwards when a *billed* remote sandbox outlives it. Sessions that exit
  normally are still not restarted and still release their `:max_children`
  slot; only abnormal exits are now restarted.

- **Elixir lower bound raised to `~> 1.19`, was `~> 1.18`.** The new
  `CrowdControl.Provider.Gce` needs `:gcp_compute`, which declares
  `elixir: "~> 1.19"`. A `Version.match?/2` guard in `mix.exs` would have kept
  the 1.18 bound nominally alive while leaving the GCE provider untested there,
  and an untested bound is a claim rather than a guarantee — the same principle
  that put a lower-bound leg in CI in the first place. The CI matrix's 1.18.3
  leg is replaced by a 1.19 leg pinned to the new floor, so the bound stays
  tested rather than merely declared.

  `:ssh` is now listed in `extra_applications`. It is an OTP application rather
  than a Hex dependency, so it cannot be made `optional: true` the way `:req`
  and `:kubereq` are, and naming it is the only way to get a release that
  actually contains it. The cost, stated plainly: `:ssh` starts for every
  consumer, including those who never touch the GCE provider. It is a small
  supervisor tree that listens on nothing unless a daemon is explicitly
  started.

### Added

- **`docs/` — four guides, wired into ExDoc under "Guides".**
  [`architecture.md`](docs/architecture.md) (the four layers and what each is forbidden to know),
  [`sandboxes.md`](docs/sandboxes.md) (how a sandbox actually works: FIFO and tee file, byte-exact
  resume, PID 1's exit-status relay, and the HTTP-agent alternative),
  [`providers.md`](docs/providers.md) (container, Compose stack, GCE spot VM) and
  [`operations.md`](docs/operations.md) (store, reaper, reattach across a node restart, log
  redaction, what to alarm on). 13 mermaid diagrams, every one parsed with mermaid 11 rather than
  eyeballed. `SECURITY.md` stays the authority on threat model and egress; the guides link to it
  instead of restating it.
- **`examples/sandbox_lifecycle.exs`** — the sandbox with the bytes visible, driving
  `Backend.Docker` directly rather than through a session: provision before any CLI exists, a
  refused second `exec/4`, three prompts through the FIFO, a reattach at a byte offset that lands
  *mid-line*, and a killed CLI producing `:eof` plus `{:ok, 137}`. Needs Docker and `alpine`; no API
  key, because the "CLI" is a shell loop that echoes JSON lines — which is itself the point.

- **A release channel for the `sandboxd` agent tarball: `sandboxd-v*`.** CI built
  `sandboxd-linux-{amd64,arm64}.tar.gz` and its `.sha256` on every run, but only
  attached them to a GitHub release on a `v*` tag — the same tag that publishes to
  Hex. So the artifact that `CrowdControl.Provider.Gce` *requires* as
  `:sandboxd_url` could not be published without also cutting a package release,
  and in practice was never published at all: the docs carried a placeholder
  `OWNER/REPO/releases/download/vX/` URL.

  `sandboxd-v*` now publishes the tarball alone — `refs/tags/sandboxd-v…` does not
  match the `refs/tags/v` gate, so Hex is untouched — while `v*` continues to do
  both, since a package release should ship the agent it documents. Release
  procedure is in `CONTRIBUTING.md`.

- **GCE provisioning telemetry.** `CrowdControl.Provider.Gce`'s acquire/1 is minutes
  long and was opaque; it now emits `[:crowd_control, :gce, :phase]` with
  `%{duration_ms: n}` and `%{phase: :insert | :running | :ssh | :health, result:
  :ok | :error, instance_name: _, zone: _}`. Failures are emitted too, because
  "it timed out" is not actionable while "`:ssh` timed out" names the firewall
  rule. This is also how `:ready_timeout` stops being guesswork: the moduledoc
  tells callers to tune it for their own image, and now they can measure it.

- **omp support.** [omp](https://omp.sh/) can now drive a session, alongside
  Claude Code and Open Code. Select it with `agent: :omp` (or just
  `executable: "omp"`, which infers the adapter):

  ```elixir
  CrowdControl.run("Summarize this repo", agent: :omp, approval_mode: "yolo")
  ```

  The adapter runs `omp --mode rpc` and speaks its newline-delimited JSON-RPC
  protocol: a `get_state` handshake surfaces the session id as the usual
  `{:system_init, %{"session_id" => id}}`, and a terminal `agent_end` frame
  becomes `{:result, "success", %{"result" => text, "total_cost_usd" => cost}}`.
  Subscribers and `CrowdControl.collect/2` therefore work unchanged across a
  mixed claude/open-code/omp fan-out. Claude Code's `:permission_mode` is
  translated to omp's approval modes; Claude-Code-only options
  (`:mcp_config`, `:max_budget_usd`, `:settings`, ...) raise rather than being
  silently dropped. See `CrowdControl.Agent.Omp`.
- **Custom omp providers — vLLM, LiteLLM, any OpenAI-compatible endpoint.**
  omp resolves a provider's `baseUrl` from `models.yml` under its agent
  directory and exposes no CLI flag for it, so `:custom_provider` renders that
  file into a private `0700` temp directory and points `PI_CODING_AGENT_DIR`
  at it:

  ```elixir
  CrowdControl.run("Review this diff",
    agent: :omp,
    custom_provider: [base_url: "http://10.0.0.5:8000/v1"],
    model: "vllm/Qwen/Qwen3-Coder-30B"
  )
  ```

  Models are discovered from the server's `/v1/models` (the built-in `vllm`
  provider also reads `max_model_len`), or listed explicitly with `:models`.
  A provider `:api_key` is **never written to `models.yml`**: the config
  references it by environment-variable name and the value travels through the
  same validated `0600` env-file channel as every other credential, so it stays
  out of both disk and argv. `:agent_dir` supplies a caller-owned directory
  instead — needed for the Docker and Kubernetes backends, where a host temp
  dir is not visible inside the sandbox. See `CrowdControl.Agent.Omp`.
- **Subscription passthrough via `:oauth_token`.** Sessions could bill an
  Anthropic API key but had no first-class way to bill a Claude
  Pro/Max/Team subscription headlessly. Each adapter now maps the option to the
  variable its CLI actually reads — `CLAUDE_CODE_OAUTH_TOKEN` for Claude Code,
  `ANTHROPIC_OAUTH_TOKEN` for omp — through the same validated `0600`
  environment channel as every other credential:

  ```elixir
  CrowdControl.run("Explain this repo", agent: :omp, oauth_token: token)
  ```

  A host that has already run `/login` needs nothing at all: omp reads its
  stored logins from `~/.omp/agent/agent.db`, so plain sessions inherit the
  subscription automatically. `:custom_provider` is the exception, because it
  relocates the agent directory and leaves that store behind —
  `inherit_auth: true` links it back in, letting one session reach both a
  self-hosted endpoint and Anthropic. Off by default: it exposes the OAuth store
  to a session whose `bash` tool may be talking to a third-party endpoint.
  README has a per-agent credentials matrix.
- **`CrowdControl.Agent` behaviour.** The CLI dialect a session speaks —
  argv plus wire format — is now a pluggable adapter
  (`CrowdControl.Agent.ClaudeCode`, `CrowdControl.Agent.Omp`, or your own
  module). `CrowdControl.CLI` and `CrowdControl.Protocol` are unchanged and
  remain the Claude Code implementation.
- **Results carry the turn they belong to.** Every `{:result, _, map}` now
  includes `map["turn"]`, and `CrowdControl.Session.current_turn/1` reports the
  turn in flight. `CrowdControl.collect/2` reads it before subscribing and
  ignores results from earlier turns — without that, `subscribe/1`'s history
  replay handed a collector the *previous* turn's result the instant it
  attached, which multi-turn sessions made reachable.
- **Pluggable sandbox backends.** `CrowdControl.Backend` behaviour, with
  `CrowdControl.Backend.Local` (the default; a local subprocess, behaviourally
  identical to previous releases) and `CrowdControl.Backend.Docker` (one
  container per session). Select with
  `backend: {CrowdControl.Backend.Docker, image: "..."}`.
- **`CrowdControl.Backend.Kubernetes`.** A third backend: one Pod per session,
  driven over the API server, `reattachable?/0 == true`. Session-facing
  semantics are indistinguishable from the Docker backend — same FIFO/tee I/O,
  same byte-exact resume, same reader contract. Three differences are not
  cosmetic:

  - The exec API has no `env` parameter, so the environment is written as a
    file over the exec **stdin** channel at `umask 077` and sourced *and
    unlinked* before the CLI starts. Secrets never enter argv, never enter the
    Pod object, and therefore never reach etcd — unlike `env` in the Pod spec
    or a `Secret` plus `envFrom`, both of which were rejected for that reason.
  - **Hardening regression: there is no `PidsLimit` equivalent.** Docker's
    512-PID fork-bomb ceiling has no Pod-spec counterpart; `podPidsLimit` is
    node-level kubelet configuration. A fork bomb in model output is unbounded
    from anything this library can set, and an operator who needs the ceiling
    must configure it on the nodes.
  - **Hardening regression: `noexec,nosuid` is not expressible.** Docker's
    `Tmpfs` takes mount flags; `emptyDir` mounts `rw,relatime` with no flag
    control, so `/tmp` can stage and execute a binary even under
    `readOnlyRootFilesystem: true`.

  Against those, two requirements with no Docker analogue are applied and are
  not overridable: `automountServiceAccountToken: false` (a projected API token
  inside a sandbox running untrusted model-driven code is a sandbox escape) and
  `enableServiceLinks: false`. `:network` is explicit (`:deny_all` |
  `{:policy, name}` | `:unrestricted`) because a Pod always has cluster
  networking, and `:deny_all` runs a one-time per-cluster probe proving the
  policy is actually enforced — a NetworkPolicy object is accepted by every API
  server but only enforced by a CNI with a policy controller. See
  [SECURITY.md](SECURITY.md#the-kubernetes-backend).
- **Session durability and reattach.** `CrowdControl.Store` behaviour with
  `Store.ETS` (default, in-memory) and `Store.DETS` (disk-backed, survives a
  node restart). Neither adds a dependency.
- **`CrowdControl.Reaper`.** Reconciles live sandboxes against stored records at
  boot and on a timer: reattaches recorded ones, destroys orphans, prunes stale
  records. This is the only real guarantee that a billed sandbox is cleaned up,
  since `terminate/2` never runs on `SIGKILL`. Fail-open by design — a failed
  listing is skipped, never read as "nothing is live".
- **Byte-exact resume.** A session interrupted mid-line reattaches and resumes
  without losing or duplicating a byte, via a persisted byte offset into the
  sandbox's output file plus the in-flight partial line.
- `:max_stream_bytes` session option — caps a session's *total* output and
  broadcasts `{:error, :stream_too_large}`, complementing `:max_line_bytes`.
- `:owner_id` config, stamped onto every sandbox as a label, so multiple nodes
  cannot reap each other's sandboxes.
- Optional `:req` dependency, needed only for `CrowdControl.Backend.Docker`.
- Optional `:kubereq` dependency, needed only for
  `CrowdControl.Backend.Kubernetes`.
- Sandbox hardening options on `CrowdControl.Backend.Docker`: `:cap_drop`,
  `:security_opt`, `:pids_limit` (all applied by default), plus opt-in `:user`,
  `:readonly_rootfs`, and `:tmpfs`.
- `c:CrowdControl.Backend.scrub/1` optional callback, so a backend can strip
  credentials from its handle before persistence.
- `CrowdControl.Backend.Credentials` — the proxy-credential rewriting that
  removes (rather than overrides) a real `:api_key`, extracted from
  `CrowdControl.Backend.Docker` so both remote backends share one
  implementation. `Docker.apply_credentials/2` now delegates to it and its
  public behaviour is unchanged.
- **A provider/transport split, so a new substrate is provisioning code only.**
  `CrowdControl.Backend` already parameterized *where* it provisioned, but each
  substrate had to bring its own byte transport too — the Docker backend's
  FIFO/`tee` pair, the Kubernetes backend's exec stream. A VM has no exec API at
  all, so a fourth substrate meant a fourth transport. The new
  `CrowdControl.Provider` behaviour owns infrastructure lifecycle
  (`acquire`/`reconnect`/`release`/`list_live`/`age_ms`/`scrub`) *underneath* a
  single transport:

  ```elixir
  CrowdControl.run("Review this diff",
    backend:
      {CrowdControl.Backend.Sandboxd,
       provider: {CrowdControl.Provider.Docker, image: "crowd_control/sandbox:dev", egress: :allow}}
  )
  ```

  Three load-bearing contracts, all stated in `CrowdControl.Provider`'s
  moduledoc: `acquire/1` returns only once the agent has answered
  `GET /v1/health` (provisioning that reports success early is the single
  largest source of flaky remote backends, and `insert_and_wait/3` on GCE waits
  for the *operation*, never the guest); `release/1` is idempotent and treats
  "already gone" as success; and the endpoint is **never** persisted, because a
  published port is reassigned on every container start. The behaviour is graded
  on admitting a Kubernetes provider as ~200 lines of provisioning code, and
  that mapping table is written out in the moduledoc — writing it is what
  revealed that `Provider.Endpoint` needs `headers` as well as `token`, since
  the API server's pod proxy consumes `authorization` for its own credential.

  `CrowdControl.Backend.Docker` is unchanged, undeprecated, and still works with
  any image that has `sh` and `tail`. The new path needs an image containing the
  agent, which is the trade it asks you to make.
- **`CrowdControl.Backend.Sandboxd` — one HTTP transport for every substrate.**
  Talks to `sandboxd`, an OTP release running inside the sandbox (nested app in
  `sandboxd/`, four dependencies, its own release). The agent's capture file is
  byte-for-byte the same artifact as the Docker backend's `tee` file, so the
  `%{byte_offset:, buffer:}` cursor is unchanged and `start_reader/3` at offset 0
  *is* the resume path. Offsets are 0-indexed here: `tail -c +N` is 1-indexed
  and that `+ 1` is a documented hazard this transport simply does not have.
  Backpressure reuses the Docker backend's proven cancel-and-re-request shape.
- **`CrowdControl.Provider.Docker`** — one container per sandbox, agent port
  published on `127.0.0.1`. `:egress` is **required** and has no default; see
  Security below for why it cannot be inferred.
- **`CrowdControl.Provider.Compose`** — a per-session stack over the Engine API
  with no `docker compose` CLI dependency (the Engine API has no compose
  endpoints; compose is a client-side Go plugin). Networks, volumes, ordered
  health-gated startup, compose-compatible labels for `docker compose ls|ps`
  interop — and deliberately *not* `config-hash`/`version`, which would make the
  compose CLI believe it owns the stack and recreate it. Teardown order is
  forced: containers, then networks, then named volumes explicitly, because a
  network `DELETE` fails 403 while attached and `?v=true` removes only anonymous
  volumes.
- **`CrowdControl.Provider.Gce`** — a Compute Engine spot VM per sandbox via the
  optional `{:gcp_compute, "~> 0.2"}`, reached through an OTP `:ssh` tunnel with
  a per-session ed25519 key generated in memory that never touches disk.
  `max_run_duration` plus `instanceTerminationAction: DELETE` is a *server-side*
  orphan backstop that needs no BEAM, because the reaper cannot help if the node
  dies mid-provision and a leaked spot VM bills forever.
- **`CrowdControl.Backend.Docker.HostConfig`** — the single definition of
  container hardening, now shared by `Backend.Docker` and `Provider.Docker`. Two
  copies would drift, and the failure mode is silent: a sandbox that quietly
  lost `CapDrop: ALL` looks exactly like one that did not.
- **`:custom_provider` now works on a remote sandbox.** `CrowdControl.Agent.Omp`
  resolves a provider's `baseUrl` from `models.yml` under its agent directory,
  which previously had to already exist *inside* the sandbox — unsatisfiable
  without a file-transfer channel. With `sandbox_agent_dir: true` the rendered
  file is written into the sandbox over `PUT /v1/files` after the sandbox exists
  and before the CLI starts, via a new optional
  `c:CrowdControl.Agent.sandbox_files/1` callback. General workspace push/pull
  remains out of scope.

### Changed

- **`CrowdControl.Provider.Gce`'s `:ready_timeout` default is `180_000`, was
  `300_000` — and it is now measured rather than reasoned.** On a spot `e2-small`
  in `us-central1-a` with no bootstrap script and the release tarball in a
  same-region bucket: 8.9s for the insert operation to reach DONE, 0.0s more to
  RUNNING-with-an-address, 23.8s for sshd to accept and forward, 7.3s for the
  agent to answer `GET /v1/health`. That is **31.1s** inside the window
  `:ready_timeout` actually bounds, and **39.9s** end to end.

  The new default is ~6x the measured requirement, sized for a bootstrap script
  that installs a CLI rather than for the bare case. Lowering it also tightens
  `:max_run_duration`, whose floor is derived from it — so the orphan backstop is
  no longer inflated by an over-cautious readiness window. The moduledoc, README
  and `examples/gce_spot_vm.exs` carry the measurement instead of a caveat saying
  it was never taken.

  Also verified in the same run: `scheduling.maxRunDuration` plus
  `instanceTerminationAction: DELETE` really does remove the instance. A VM with
  a 600s budget was deleted by GCE at +594s, with nothing local involved.
- **Dependency floors raised: `req ~> 0.7`, `kubereq ~> 0.4.5`,
  `gcp_compute ~> 0.3`.** These three move together and cannot be separated:
  `gcp_compute` 0.3.0 requires `req ~> 0.7` (for the `:decoders` hook — 0.6 had
  only the now-deprecated `:decode_json`), and `kubereq` 0.4.4 pins
  `req ~> 0.6.0`, so taking one forces the others. The `:req` constraint here is
  unchanged at `~> 0.5`, which already admits 0.7. Resolving the tree also pulled
  mint 1.9.0 → 1.9.3 and hpax 1.0.3 → 1.0.4, clearing five security advisories.

  `gcp_compute` 0.2.0 could not complete a single launch against real GCP: every
  bodyless `POST` was rejected `411 Length Required`, which is
  `zoneOperations.wait`, which is how both `insert_and_wait/3` and
  `delete_and_wait/3` finish. 0.3.0 fixes it. **The GCE provider now passes its
  integration suite against real infrastructure** — three tests that had never
  executed before.
- **A rejected Kubernetes exec/log upgrade is now reported asynchronously.**
  `kubereq` 0.4.5 changed the model: its Req adapter answers a synthetic `101`
  and casts the real request to a connection process, so `open_exec/5` returns
  `{:ok, pid}` while the handshake is still in flight and a 404/400/403 cannot
  surface as a return value. It arrives instead as
  `{:exec_down, pid, {:k8s, {:upgrade_failed, status}}}` — normalized into the
  same vocabulary as before, so a consumer does not have to know which kubereq
  reported it, or whether it was synchronous. The reader already treated a
  channel death as a stream drop, so resume behaviour is unchanged.

  One consequence worth knowing: `:connected` is now delivered *before* the
  upgrade is attempted, so it is no longer evidence that a channel exists.
- **A Kubernetes `write/2` that times out now returns
  `{:error, {:k8s, :write_indeterminate}}`** rather than `{:k8s, :exec_timeout}`.
  The exec task is killed brutally and the Mint socket dies with it, but the API
  server may already have run the `printf` — so the prompt may or may not be in
  the FIFO. Reported as a plain timeout, the obvious response is to retry, which
  delivers the same prompt twice. Naming the uncertainty lets a caller decide.
- **`CrowdControl.Backend.Kubernetes.API.exec_stdin/5` takes an options list**
  (was `exec_stdin/4`), so the caller pins `:container`.

### Fixed

- **`CrowdControl.Backend.Docker`'s exec/4 refuses a second call** with
  `{:error, {:docker, :already_started}}`, matching `Backend.Kubernetes` and
  `Backend.Sandboxd`. `tee` opens the tee file `O_TRUNC`, so a second launch
  silently truncated it and every persisted byte offset then pointed into a
  different file — no error, just a session replaying or skipping output.

  The check asks the *container*, not the handle: a handle rebuilt by
  `list_live/1` on another node knows nothing about a previous exec, and the
  launcher and status files are the only durable record. It cannot ride along
  inside the launch command the way the Kubernetes one does, because Docker's exec
  is detached and its exit code is never observable — so it costs one extra round
  trip, once per session. It fails *closed*: refusing wrongly is a clear error on
  a retryable path, while allowing wrongly corrupts every cursor silently.
- **The Kubernetes credential write uses a binary websocket frame.**
  `Kubereq.PodExec.send_stdin/2` builds `{:text, <<0, data>>}`, but channel 0 is a
  byte channel and RFC 6455 requires a text frame's payload to be valid UTF-8,
  permitting a peer to fail the connection on anything else.

  Measured rather than assumed: pushing `<<"prefix-", 0xFF, 0xFE, "-suffix">>`
  through both opcodes against v1.35.6+orb1 delivered all 16 bytes intact either
  way, so this apiserver does not enforce the rule and the defect was **latent,
  not live**. The exposure is an intermediary that does enforce it, where the
  symptom would be an unexplained close on the credential write. The correct
  opcode costs nothing, so it is now used; there is deliberately no regression
  test, because every server reachable from here accepts both and such a test
  could not fail.

- **A crashed CLI no longer hangs a Docker session forever, either.** The same
  defect as the Kubernetes one below, in the same shape, found by asking whether
  that one had a twin rather than by a report — and `Backend.Docker` is the
  default remote backend, so this was the more exposed of the two. Its PID 1 was
  `sleep infinity` and the CLI is started by a *detached* exec, so PID 1 never
  spawned it and could not reap it. Measured on a live daemon before the fix: kill
  the CLI and `alive?/1` still answered `true`, `await_exit/2` answered `:timeout`
  forever, no `:eof` ever reached the session, and the container billed on.

  PID 1 now waits for a status the launch pipeline writes after `tee` drains and
  exits with the CLI's own code — `await_exit/2` reports `137` for a SIGKILLed CLI
  instead of never returning — and a launcher killed before it can report is
  detected through its pid file rather than waited on forever. Both paths have
  live tests.

- **`CrowdControl.Provider.Gce.API.list_all/3` actually paginates.** It passed
  `:maxResults` and `:pageToken`; the library's option is `:max_results` and
  `:page_token`. 0.2.0 forwarded unrecognised options to the wire untouched, so
  both were ignored: every call fetched the API server's default first page and
  the page token never advanced. A project with more sandboxes than one page
  would have reported the rest as gone — and `CrowdControl.Reaper` deletes the
  store record of a sandbox it cannot see. 0.3.0 rejects unknown options, which
  is how this surfaced.
- **A crashed CLI no longer hangs a Kubernetes session forever.** The sandbox
  container's PID 1 was `sleep infinity`, and `setsid` makes the CLI a
  grandchild of it, so nothing in the container noticed the CLI die: the Pod
  stayed `Running`, `tail -f` never ended, no `:eof` reached the session, and the
  Pod billed indefinitely. PID 1 now waits for the status the launch pipeline
  writes *after* `tee` drains and exits with the CLI's own code, so
  `Backend.Kubernetes.await_exit/2` reports `137` for a SIGKILLed CLI instead of
  never returning. A launcher killed before it can report (an OOM kill of the
  process group) is detected through its pid file rather than waited on forever.
- **`CrowdControl.Backend.Kubernetes.API.open_exec/5` no longer kills a caller
  that does not trap exits.** `Kubereq.PodExec.start_link/1` links to whoever
  starts it and stops with the transport error as its reason, and a link signal
  is not something a `rescue`/`catch :exit` can intercept — so a routine
  websocket blip killed the caller outright. The channel is now started by a
  dedicated trapping owner that holds the only link, and a channel death arrives
  as an `{:exec_down, pid, reason}` message. The owner monitors the consumer, so
  a channel cannot outlive the process it delivers to.
- **A failed write of the Kubernetes credential file is no longer reported as
  success.** `exec_stdin` returned `:ok` on the first close frame and discarded
  websocket channel 3 entirely, so a write that could not create the file looked
  fine and the CLI then started with no credentials and failed later, elsewhere,
  for a reason that named none of this. The channel-3 `Status` is now decoded
  with the same `exec_status/1` the other exec paths use.
- **The Kubernetes credential file is written to a named container.** Every other
  exec pinned `:container`; this one did not, so on a multi-container Pod the API
  server chose where the secret landed. It worked only because the sandbox Pod
  has one container plus an already-exited init container.
- **`Backend.Kubernetes.exec/4` refuses a second call** with
  `{:error, {:k8s, :already_started}}`, matching `Backend.Sandboxd`. `tee` opens
  the tee file `O_TRUNC`, so a second launch silently truncated it and every
  persisted byte offset then pointed into a different file — no error, just a
  session replaying or skipping output. The guard runs before the credential file
  is written, so a refused call cannot re-plant a secret that only the launcher
  unlinks.
- **A reattached Kubernetes session resumes against the file its offset was
  measured in.** A handle rebuilt by `list_live/1` took `:tee_path`,
  `:fifo_path` and `:env_path` from the *caller's* options — a reaper's, usually
  — so a session provisioned with custom paths resumed against the defaults,
  reading a file that does not exist. The paths are now persisted as Pod
  annotations and rebuilt from there; Pods created before this change fall back
  to the caller's options as before.
- **The Kubernetes reader asks the API server once per reconnect burst, not once
  per attempt.** One blip produced five `GET /pods/{name}` calls in about three
  seconds. Steady-state idle polling is unchanged and deliberately uncached: one
  Pod carries exactly one reader, so there is nothing for a shared cache to
  collapse.
- **`Session.send_prompt/2` no longer rejects a prompt after the first result.**
  A `{:result, _, _}` ends a *turn*, not the process: both
  `claude --input-format stream-json` and `omp --mode rpc` keep reading stdin
  afterwards, so the old `{:error, :completed}` made multi-turn conversations
  impossible. A prompt is now accepted while the subprocess is alive and moves
  the session back to `:running`; only an exited subprocess is terminal.
- **A local-only omp prompt no longer hangs the collector.** A slash command
  omp answers itself (`/tools`) emits no `agent_end`; its only completion
  signal is `agentInvoked: false`, on the prompt response or a later
  `prompt_result`. Both are now terminal, producing
  `{:result, "success", %{"local_only" => true}}`. Previously
  `CrowdControl.run("/tools", agent: :omp)` blocked for its full deadline.
- **A type-drifted omp frame no longer kills the session.** `decode_line/1`
  runs inside `handle_cast/2`, so a `get_state` payload whose `"model"` was a
  string rather than an object raised `FunctionClauseError` and took the
  session down. Every field read is now shape-guarded, and `"sessionId"` is
  clamped to a binary before it reaches `Session` and `Store`, both of which
  spec it as `String.t() | nil`.
- **A failed handshake write stops the session instead of wedging it.**
  `Session.init/1` now returns `{:error, {:handshake_failed, reason}}` and
  tears down the sandbox, rather than leaving an omp session in `:starting`
  with no session id until its inactivity timeout.
- **Options set inside a `{Backend, config}` tuple reach the agent's framing
  callbacks.** `build_command/1` always saw the merged list; `init_frames/1`
  and `encode_prompt/3` saw the raw one, so `:streaming_behavior` written
  there was silently inert.
- **An explicitly-`false` Claude-Code-only option no longer raises for omp.**
  `bare: false` and `strict_mcp_config: false` request default behaviour, so
  dropping them changes nothing; raising broke shared option lists in a mixed
  fan-out.
- **An invalid `:streaming_behavior` is rejected by `build_command/1`.** It
  used to surface only when a prompt was encoded — inside `Session.init/1` or
  `handle_call/3` — killing the session and the calling process.
- **A crashing HTTP stream task no longer takes a session down without an
  `:eof`.** `Req`'s `into: :self` machinery `spawn_link`s its worker to the
  reader, so an abnormal task exit killed the reader before it could cast
  `:eof` — and `Session` keeps the reader pid but never monitors it, so the
  session died with no end-of-stream at all. Both readers now trap exits and
  treat an abnormal task exit as a transport failure. Found while building
  `Backend.Sandboxd` and back-ported to `CrowdControl.Backend.Docker`, which had
  the identical latent bug.
- **A mid-stream transport failure is normalized like every other failure.**
  `Req.parse_message/2` yields `%Finch.TransportError{}` for a connection that
  died under an open stream, while `Req.get/2`'s *return* yields
  `%Req.TransportError{}` for a connect-phase failure. Only the second was
  folded into the backend's error vocabulary, so the first leaked a raw struct
  out of the backend in exactly the case most likely to reach a log line.

### Security

- **No kubeconfig in a crash report.** `kubereq` 0.4.5 casts the whole
  `%Req.Request{}` to its connection process, so when a websocket upgrade is
  rejected — a routine event: a Pod reaped mid-session answers 404 — OTP's crash
  report printed that request as the process's last message. Measured: with a
  certificate kubeconfig that is `cert: <<48, 130, …>>` in a ~2 KB `:error` line;
  with a **token** kubeconfig, which is the in-cluster ServiceAccount posture,
  `Req` redacts the `authorization` header but prints
  `options.kubeconfig.current_user["token"]` in full.

  `CrowdControl.LogRedactor` is a `:logger` primary filter, installed at
  application start, that replaces the request term, the process state and the
  client info with `:redacted_by_crowd_control`. It fires only for reports that
  actually carry a `%Req.Request{}` or a Kubereq.Connect state, so no other
  library's crash reports are touched, and it never drops an event — the reason,
  the process name and the stacktrace survive, because an invisible crash is a
  worse bargain than a redacted one. Opt out with
  `config :crowd_control, redact_logs: false`. Verified on a live cluster.
- **A pod-log failure no longer carries the response headers into its error
  term.** `PodLogs` fails asynchronously under kubereq 0.4.5 too, so an inspected
  `%Mint.WebSocket.UpgradeFailureError{}` — status *and* every response header —
  became the error reason. It is now the same `{:upgrade_failed, status}` the exec
  path reports.
- **The Kubernetes `:deny_all` enforcement probe no longer reports a boundary
  that is not there.** It fetched `http://1.1.1.1`, which made a security
  decision depend on internet reachability: one dropped packet inside the 5 s
  window failed the guarded run, and a failed guarded run was read as "the policy
  stopped it". Observed reporting enforcement on a cluster with no policy
  controller at all, which ships a sandbox believing it has a network boundary it
  does not have. The probe now performs a TCP connect to the API server's
  ClusterIP — no DNS, no TLS, no internet — and reports enforcement only when the
  guarded container actually **ran** and an identical fetch **succeeded** without
  the policy in place. Anything else is inconclusive, and inconclusive is never
  cached and never treated as enforcement. `:network_probe_url` still selects an
  internet target for callers who specifically want that proven blocked.
- **Abandoned probe objects no longer accumulate on the cluster.** The probe
  cleans up in an `after` block, which does not run when the process is *killed*
  — an ExUnit timeout, a supervisor shutdown — and the objects carry no owner
  hash, so nothing else could ever match them. Each probe now sweeps abandoned
  ones older than five minutes, so a killed run self-heals.
- **A `WithClauseError` from the websocket stack is bounded structurally.**
  `Kubereq.Connect.create_stream/4` can raise it during `Enum` evaluation, where
  nothing wraps it into the `MatchError` the normalizer already handled — leaving
  a length-capped `Exception.message/1` of an inspected `%Mint.HTTP1{}`, which
  holds the socket and, transitively, the connection's transport options.
- **Sandbox containers are hardened by default.** `CapDrop: ALL`,
  `no-new-privileges`, and `PidsLimit: 512`. The PID ceiling is independent of
  `:memory`/`:cpus`, neither of which bounds process count, so without it a fork
  bomb in model output could exhaust the host.
- **Networking is never inferred.** Setting `:proxy_url` or `:api_url` without
  an explicit `:network_mode` now returns
  `{:error, {:docker, :network_mode_required}}` instead of silently selecting
  `bridge` — which grants general outbound access and makes an egress proxy
  advisory rather than enforcing.
- **Credentials are no longer persisted.** `:api_key`, `:session_token`, and
  `:env` are stripped from both session opts and the backend handle before any
  store write. `Store.DETS` restricts its file to `0600` in a `0700` directory.
- **The reaper re-checks ownership locally** before destroying a sandbox rather
  than trusting the daemon-side label filter alone, and a session now records
  the same owner its sandbox is labelled with. Previously a `:owner` set in
  backend config produced records the reaper could not match, causing it to
  classify every live sandbox as an orphan.
- **A reader transport error no longer kills its session.** A mid-stream failure
  now casts `:eof` as the backend contract requires, instead of raising in a
  linked process.
- **No agent credential is ever persisted.** `CrowdControl.Backend.Sandboxd`
  derives each sandbox's bearer token by HMAC-SHA256 over a configured
  `:sandboxd_secret` and the `session_key` the store already holds, so reattach
  recomputes it with nothing at rest. `scrub/1` drops the endpoint **wholesale**
  rather than field-by-field, so a future field on it cannot leak by omission,
  and `Store.secret_keys/0` gains `:sandboxd_secret` and `:gce_config` (the
  latter holds a live token-provider argument and is not a secret by name, which
  is exactly why it needs naming). One documented cost: rotating
  `:sandboxd_secret` fails reattach closed with `{:sandboxd, :unauthorized}` for
  every sandbox started under the old secret. That is the intended trade against
  a live credential in DETS, and the integration suite asserts it.
- **The agent port is never routable, and `:egress` is never inferred.** On one
  container, `Internal: true` and a published port are mutually exclusive —
  publishing requires a non-internal endpoint, and attaching one restores full
  internet egress. Confirmed six independent ways against Docker 29.4.0, and the
  failure is *silent*: `create` answers `201` with `"Warnings": []` while
  `NetworkSettings.Ports` reads `{"8080/tcp": null}`. So
  `CrowdControl.Provider.Docker` requires an explicit `:egress` (`:allow` or
  `:no_nat`) exactly as `Backend.Docker` requires an explicit `:network_mode`,
  and it does **not** claim to block egress. `:no_nat` blocks the internet but
  leaves the Docker host, sibling containers and embedded DNS reachable — "no
  NAT", not "dropped" — and SECURITY.md says so rather than glossing it.
  `HostIp: "127.0.0.1"` is sent on every binding, because omitting it publishes
  two bindings on every interface.
- **A per-session internal network makes the proxy footgun unreachable.**
  `CrowdControl.Provider.Compose` puts the sandbox on an `Internal: true`
  network with no port bindings and reaches it through a synthesized dual-homed
  `socat` forwarder, so there is no `bridge` for a caller to choose and the
  `bridge`-defeats-the-proxy failure mode does not exist for this provider. The
  forwarder's own publish network disables IP masquerade, so it has no internet
  either. Verified against a live daemon: the sandbox cannot reach `1.1.1.1`,
  can reach its sidecar by alias, and the host can reach the agent.
- **GCE sandboxes are reached only through an SSH tunnel.** The agent binds the
  VM's loopback; port 22 is the only reachable port, and the per-session ed25519
  key is generated in memory, set as *instance-level* metadata (a project-wide
  key would apply to every VM in the project), and never written to disk.
  Startup interpolates no secret into the script body and verifies a **mandatory**
  SHA-256 on the release download. GCE metadata is readable by in-sandbox code,
  which SECURITY.md states plainly rather than hiding.
- **`PUT /v1/files` rejects path traversal rather than normalizing it**, on both
  the client and the agent. A request for `/v1/files/../../etc/passwd` is
  refused with `400`; a legitimate absolute path never needs `..` to express
  itself. The route exists solely so omp's `:agent_dir` obligation is
  satisfiable remotely.
- **The agent's `401` has an empty body and a constant-time comparison.** A
  distinct message for "no header" versus "wrong token" tells an attacker which
  half to work on, and a byte-wise comparison leaks the token to anything that
  can time responses — which, for a loopback-published port, is every process on
  the host. `GET /v1/health` is the only unauthenticated route and returns
  `{"ok": true}` and nothing else, because a provider must poll it before any
  token round trip can have succeeded.
- **The agent refuses to boot without a token.** A missing `CC_SANDBOXD_TOKEN`
  is a hard startup failure, not a warning that degrades into an
  unauthenticated process-exec endpoint. The release also disables Erlang
  distribution, so it never registers with EPMD and opens no port that
  `CC_SANDBOXD_BIND` does not govern.

- **Strict env-var validation.** `CrowdControl.CLI.build_env/1` now rejects env
  keys that don't match `^[A-Za-z_][A-Za-z0-9_]*$` and values containing null
  bytes or newlines, blocking shell injection through the env-file mechanism.
- **Path sanitization for argv-bound options.** `:add_dir`, `:mcp_config`,
  `:plugin_dir`, `:settings_file` (and the deprecated `:settings` path form)
  are passed through `CrowdControl.CLI.sanitize_path!/1` which rejects null
  bytes and control characters and expands to an absolute path. `:extra_args`
  and `:agents` strings are checked for control characters.
- **Prompt validation hardened.** `CrowdControl.Session.send_prompt/2` now
  rejects prompts that are not valid UTF-8 or contain null bytes, in addition
  to the existing size check.
- **No more crash on malformed subprocess output.** `CrowdControl.Protocol.decode_line/1`
  returns `{:invalid_json, raw_line}` instead of raising; the Session GenServer
  logs the line at `:debug` and keeps running. Previously a malformed line
  would crash the session.
- **Per-session env directory.** The shell file holding API-key env vars is now
  written inside a per-session `0700` subdirectory under the system temp dir
  and torn down with `File.rm_rf/1` on terminate/EOF.

### Added

- `CrowdControl.CLI.sanitize_path!/1` public helper.
- `:settings_file` and `:settings_json` options on `CrowdControl.CLI.build_command/1`
  as a typed replacement for the overloaded `:settings` option.
- `@spec` and `@type` annotations on every public function in
  `CrowdControl`, `CrowdControl.Session`, `CrowdControl.CLI`, `CrowdControl.Protocol`.
- `examples/` directory with seven runnable scripts (`single_session.exs`,
  `parallel_models.exs`, `streaming.exs`, `multi_turn.exs`, `custom_mcp.exs`,
  `error_handling.exs`, `bounded_pool.exs`).
- `SECURITY.md` with private disclosure address and supported-version policy.
- `CONTRIBUTING.md` with local dev workflow and security-sensitive checklist.
- `LICENSE` (Apache-2.0).
- New tests: full `CrowdControl.Session` GenServer coverage, end-to-end
  orchestrator tests against a `test/support/fake_cli.sh` stand-in, security
  tests for shell escaping and env/path validation, and StreamData property
  tests for the protocol.
- CI jobs: `coverage` (ExCoveralls), `sobelow`, `audit` (`mix hex.audit` +
  `mix deps.audit`), `docs` (`mix docs` artifact), and macOS test matrix entry.
- Hex package metadata: description, package, docs, `ex_doc`, `LICENSE`,
  `SECURITY.md`, `CONTRIBUTING.md` included in tarball.

### Changed

- **Breaking:** the `:settings` option is deprecated. A string starting with
  `{` is heuristically treated as inline JSON; anything else is treated as a
  file path. Switch to `:settings_file` or `:settings_json` for unambiguous
  behavior.
- **Behavior:** sessions now default to a 5-minute idle timeout. Pass
  `timeout: :infinity` to opt out, or override per session.
- `CrowdControl.start_sessions/1` clamps `Task.async_stream` concurrency to
  the configured `:max_sessions` cap, returns `{:ok, []}` for an empty list,
  and normalizes task crashes into `{:error, {:task_exit, reason}}`.
- `CrowdControl.stop_all/1` now stops sessions in parallel (up to 16 at a
  time) with a 15s per-session timeout, instead of serially.
- `CrowdControl.broadcast/2` catches `:exit` from dead session pids.
- `CrowdControl.Session` is marked `restart: :temporary` so a failing CLI
  subprocess does not trigger `DynamicSupervisor` restart-intensity shutdown.
- `:max_sessions` is validated at application boot as a positive integer,
  raising a clear `ArgumentError` otherwise.
- `net_runner` bumped to `~> 1.2` (was `~> 1.0`).

### Fixed

- `lib/crowd_control.ex`: `Task.async_stream` no longer matches `{:ok, _}` on
  task crashes — `{:exit, reason}` is handled explicitly.

## 0.1.0

### Security

- API key no longer exposed in `ps` (env file with `0600` perms, deleted before
  exec).
- Non-root Docker container; all Linux capabilities dropped.
- Read-only filesystem with tmpfs for writable paths.
- Resource limits in `docker-compose.yml` (memory 4G, CPU 2.0).

### Added

- `CrowdControl.healthy?/0` and Docker `HEALTHCHECK`.
- `:timeout` and `:max_prompt_size` session options.
- `:max_sessions` application config caps concurrent sessions.
- `CLAUDE_CODE_VERSION` Docker build arg.
- Logger calls on session start / completion / error / timeout.

- Initial release.
