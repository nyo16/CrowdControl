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
  `validate_env!/1`, `shell_escape/1`).
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
