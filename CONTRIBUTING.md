# Contributing to CrowdControl

Thanks for considering a contribution!

## Development setup

```sh
# Elixir 1.18 + OTP 27 (mise / asdf both work)
mise install elixir@1.18.3 erlang@27.3
# or:  asdf install

mix deps.get
mix compile
```

## Before opening a PR

Run the same checks CI runs:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer
mix sobelow --skip
mix hex.audit
mix deps.audit
mix test
mix coveralls.html      # open cover/excoveralls.html
mix docs                # open doc/index.html
```

Integration tests are tagged `:integration` and excluded by default:

```sh
mix test --only integration
```

## Security-sensitive changes

Anything touching one of these requires extra care and a test that
exercises the adversarial input:

- `CrowdControl.CLI.sanitize_path!/1`
- `CrowdControl.CLI.build_env/1` / `validate_env!/1`
- `CrowdControl.Backend.Shell.escape/1` — the single shell escaper, used by
  both the local env-file mechanism and the Docker backend's prompt writes.
  There must never be a second one.
- `CrowdControl.Backend.Local`'s env-file generation (`write_env_file/1`)
- `CrowdControl.Backend.Docker`'s exec construction — secrets go in the exec
  API's `Env` array and must never be interpolated into the command string
- `CrowdControl.Protocol.decode_line/1`
- `CrowdControl.Reaper`'s fail-open reconciliation — a failed container listing
  must never be treated as "nothing is live"

See `test/crowd_control/security_test.exs` for the existing adversarial
test surface and extend it for any new attack vector you touch.

If you believe you have found a vulnerability, please follow
[`SECURITY.md`](SECURITY.md) instead of opening a public issue or PR.

## Commit style

- One logical change per commit.
- Imperative subject (`Add foo`, not `Added foo`).
- Body explains *why*; the diff already says *what*.
- Sign commits when possible (`git config commit.gpgsign true`).

## PR checklist

- [ ] `mix format` clean
- [ ] CI is green (compile, format, credo, test, dialyzer, sobelow, audit, coverage, docs)
- [ ] CHANGELOG.md updated under `## Unreleased`
- [ ] New public functions have `@doc` and `@spec`
- [ ] Security-sensitive changes have adversarial tests

## Releasing

Two independent channels. Pushing the wrong tag publishes the wrong thing, so the
distinction is worth reading once.

**`v*` — the Hex package.** Sets the version from the tag, publishes to Hex, and
*also* attaches the agent tarballs to the GitHub release.

```bash
git tag v0.2.0 && git push origin v0.2.0
```

**`sandboxd-v*` — the agent tarball only.** Builds
`sandboxd-linux-{amd64,arm64}.tar.gz` plus a `.sha256` sidecar inside the target
image (an OTP release must be built on the glibc it will run on), smoke-tests that
the amd64 one actually boots and answers `GET /v1/health`, and attaches all four
files to the GitHub release. **No Hex publish** — `refs/tags/sandboxd-v…` does not
match the `refs/tags/v` gate.

```bash
git tag sandboxd-v0.1.0 && git push origin sandboxd-v0.1.0
```

Use this channel when the agent changes but the package has not, and when you
need a URL to hand to `:sandboxd_url` — which `CrowdControl.Provider.Gce`
requires, along with `:sandboxd_sha256`, because the VM fetches it over plain
HTTPS with no credential and the checksum is the only thing making that safe.

The tarballs are also uploaded as workflow artifacts on every run, including pull
requests, so you can test a change without tagging anything.
