# Changelog

## Unreleased

### Security

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
- `LICENSE` (MIT).
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
- `CrowdControl.Application` validates `:max_sessions` is a positive integer
  at boot, raising a clear `ArgumentError` otherwise.
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
