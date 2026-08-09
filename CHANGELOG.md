# Changelog

## Unreleased

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

### Added

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
- **`CrowdControl.Agent` behaviour.** The CLI dialect a session speaks —
  argv plus wire format — is now a pluggable adapter
  (`CrowdControl.Agent.ClaudeCode`, `CrowdControl.Agent.Omp`, or your own
  module). `CrowdControl.CLI` and `CrowdControl.Protocol` are unchanged and
  remain the Claude Code implementation.
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

### Fixed

- **`Session.send_prompt/2` no longer rejects a prompt after the first result.**
  A `{:result, _, _}` ends a *turn*, not the process: both
  `claude --input-format stream-json` and `omp --mode rpc` keep reading stdin
  afterwards, so the old `{:error, :completed}` made multi-turn conversations
  impossible. A prompt is now accepted while the subprocess is alive and moves
  the session back to `:running`; only an exited subprocess is terminal.

### Security

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
