# Changelog

## Unreleased

### Security

- **Fix API key exposure**: Per-session API keys are no longer passed as process arguments (visible via `ps`). They are now written to a temporary file with `0600` permissions, sourced by the shell, and deleted before the CLI starts.
- **Non-root Docker container**: Runtime runs as `crowdctl` user instead of root.
- **Drop all capabilities**: Docker Compose services use `cap_drop: ALL` and `no-new-privileges`.
- **Read-only filesystem**: Container root filesystem is read-only with tmpfs for writable paths.
- **Resource limits**: Docker Compose services have memory (4G) and CPU (2.0) limits.

### Added

- `CrowdControl.healthy?/0` - health check function (also used by Docker `HEALTHCHECK`).
- `:timeout` session option - automatic session expiry after inactivity (milliseconds).
- `:max_prompt_size` session option - reject prompts exceeding a byte size limit.
- `max_sessions` application config - caps concurrent sessions via `DynamicSupervisor` `max_children` (default: 50).
- `{:error, :max_sessions_reached}` returned from `start_session/1` when at capacity.
- `{:error, :invalid_prompt}` returned from `send_prompt/2` for non-string input.
- `{:error, :prompt_too_large}` returned from `send_prompt/2` when prompt exceeds `:max_prompt_size`.
- `{:timeout, :session_expired}` message broadcast to subscribers on session timeout.
- `CLAUDE_CODE_VERSION` Docker build arg for pinning the CLI version.
- Docker `HEALTHCHECK` instruction.
- Logger calls on session start, completion, error, and timeout.

### Changed

- Docker runtime stage no longer includes `build-essential` (reduced attack surface).
- Docker runtime stage removes `curl` after Node.js setup.
- `test/` directory excluded from Docker build via `.dockerignore`.
- Docker Compose subscription service mounts to `/home/crowdctl/.claude` (non-root user path).

## 0.1.0

- Initial release.
