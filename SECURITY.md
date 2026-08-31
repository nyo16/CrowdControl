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

- Shell / argument / environment injection through `CrowdControl.CLI` or a
  `CrowdControl.Agent` adapter (e.g. `CrowdControl.Agent.Omp`)
  and `CrowdControl.Session` (env file generation, `sanitize_path!/1`,
  `validate_env!/1`, `CrowdControl.Backend.Shell.escape/1`).
- Sandbox escape or credential disclosure through
  `CrowdControl.Backend.Docker` (container config, exec command
  construction, environment injection).
- Sandbox escape or credential disclosure through
  `CrowdControl.Backend.Kubernetes` (Pod manifest hardening, exec command
  construction, the env-file stdin channel, NetworkPolicy posture).
- `CrowdControl.Reaper` destroying sandboxes it does not own.
- Information disclosure through temp files, logs, or process listings.
- Denial of service against the session supervisor or individual sessions
  (resource exhaustion, hang vectors).
- Container hardening regressions in the provided `Dockerfile` and
  `docker-compose.yml`.

Out of scope:

- Vulnerabilities in the upstream `claude` / `opencode` / `omp` CLIs.
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

### The Kubernetes backend

`CrowdControl.Backend.Kubernetes` runs a CLI inside a Pod over the API server.
Session-facing semantics match the Docker backend exactly. The security posture
does not, and the differences below cut in both directions.

**Secrets travel the exec stdin channel.** The Kubernetes exec API has no `env`
parameter — `pods/exec` has no such field and `kubectl exec` has no `--env` —
so the `Env` array that keeps provider keys out of argv under Docker has no
counterpart here. Instead the environment is written as a file over the exec
**stdin** channel (websocket channel 0) at `umask 077`, and the launch command
sources *and unlinks* it before the CLI starts. The bytes never enter argv,
never enter the Pod object, and therefore never reach etcd; the file is gone by
the time anything in the sandbox could read it back.

The two obvious alternatives were rejected, both for widening the blast radius
rather than narrowing it:

- **`env` in the Pod spec.** Puts the provider key in the Pod object — in etcd,
  readable by anyone with `get pods`, printed by `kubectl describe`. That trades
  an in-sandbox `ps` leak for a cluster-wide one.
- **A `Secret` plus `envFrom`.** Same etcd residency, plus `secrets` RBAC on the
  backend's identity, plus a second object left behind on a crash.

**REGRESSION: there is no `PidsLimit` equivalent.** Docker sets a 512-PID
fork-bomb ceiling deliberately and separately from `Memory`, because neither
`:memory` nor `:cpus` bounds process count. Kubernetes has no Pod-spec field for
it: `podPidsLimit` is node-level kubelet configuration. A fork bomb in model
output is therefore **unbounded from anything this library can set**. An
operator who needs the ceiling must set `podPidsLimit` in the kubelet
configuration of every node these sandboxes can land on, and until that is done
should assume a sandbox can exhaust the node's PID space for every other Pod
scheduled beside it.

**REGRESSION: `noexec,nosuid` is not expressible.** Docker's `Tmpfs` option
takes mount flags. `emptyDir` does not — it mounts `rw,relatime` with no flag
control — so `/tmp` can stage and execute a binary even under
`readOnlyRootFilesystem: true`. Verified on `v1.34.8+orb1`. Enabling
`:readonly_rootfs` is still worth it, because it stops writes everywhere except
the mounted volumes, but it does not make those volumes non-executable and must
not be read as if it did.

**Two settings are requirements, not options.** Neither has a Docker analogue,
and neither is overridable:

- `automountServiceAccountToken: false`. A default Pod is handed roughly 1.1 KB
  of projected bearer token on disk, plus a reachable API server, inside a
  sandbox running untrusted model-driven code. That is a sandbox escape, not a
  hardening nicety.
- `enableServiceLinks: false`. Otherwise every Service's host and port in the
  namespace is injected into the sandbox's environment: free cluster
  reconnaissance for anything running in there.

**Network posture is never inferred.** There is no `NetworkMode: "none"` here —
a Pod always has cluster networking — so `:network` is explicit and mandatory in
the one case where guessing removes the boundary:

- `:deny_all` — the backend creates a deny-all `Ingress`+`Egress` NetworkPolicy
  selecting the Pod, before the Pod exists, and deletes it with the Pod.
- `{:policy, name}` — a policy the caller manages. It is fetched and
  provisioning fails if it is absent, rather than trusting the claim.
- `:unrestricted` — the Pod reaches the cluster and the internet.

Omitting `:network` while setting `:proxy_url` or `:api_url` returns
`{:error, {:k8s, :network_policy_required}}`, for the same reason the Docker
backend refuses to infer `bridge`.

**A declaration is not enforcement.** Any API server accepts a NetworkPolicy
object; only a CNI with a policy controller acts on one. OrbStack accepts them
and enforces nothing — verified: a deny-all policy selecting the probe Pod, and
egress still succeeded. A backend that created the object and reported the
sandbox contained would be describing a boundary that does not exist. So
`:deny_all` runs a one-time per-cluster enforcement probe (a throwaway Pod under
a deny-all policy attempting egress) and refuses to provision with
`{:error, {:k8s, :network_policy_not_enforced}}` when egress succeeds. Set
`network_probe: false` only if you already know your CNI enforces.

**The probe's own failure mode, and why it is now a two-Pod test.** A single
blocked fetch conflates "the policy stopped it" with "it failed for some other
reason", and that direction of error is the dangerous one: a false *enforced*
ships a sandbox believing it has a boundary it does not have. This was not
hypothetical — the probe fetched `http://1.1.1.1` with a 5 s timeout, and it
reported enforcement on a cluster with no policy controller at all, because one
slow image pull was enough.

Two independent conditions must now both hold before enforcement is believed:

- the guarded container actually **ran** and exited non-zero. A Pod that never
  started — unschedulable, `ImagePullBackOff` — also reports phase `Failed`, and
  reading that as "blocked by policy" is exactly the false positive above; and
- the **same** attempt **succeeds** with no policy in place. That rules out a
  broken cluster network, an unreachable target, and a client that fails for its
  own reasons.

Anything else is `{:error, {:k8s, {:network_probe_inconclusive, reason}}}`, which
is never cached and never treated as enforcement — one flaky minute must not
become a permanent wrong answer.

The default target is a TCP connect to the API server's ClusterIP
(`$KUBERNETES_SERVICE_HOST`), which needs no DNS, no TLS and no internet: a
security decision should not depend on external reachability. `:network_probe_url`
selects an internet target for callers who specifically want *that* proven
blocked, and it is the less deterministic choice.

On a cluster that enforces nothing the guarded fetch simply succeeds, which is
conclusive on its own — so the common case still costs one Pod, not two.

**RBAC the backend needs.** In its `:namespace`, and nothing wider:

    pods            create, get, list, delete
    pods/exec       create
    pods/log        get                     # diagnostics on a failed provision
    networkpolicies create, get, delete     # only under network: :deny_all

**One place this backend is stricter than Docker.** The sandbox container keeps
`capabilities.drop: ["ALL"]` with *nothing* added. Creating the FIFO needs
`CAP_MKNOD`, once, at startup — under `drop: ["ALL"]` plus
`allowPrivilegeEscalation: false` together, `mkfifo` fails with a misleading
`ENOENT`. Adding `MKNOD` to the sandbox would fix it in one line and is what
Docker's own default capability set does, but it would hold the capability for
the life of the session in exchange for one syscall. A short-lived init
container holds it for milliseconds and exits instead.

**A dependency puts the kubeconfig in a crash report, and we redact it.**
`kubereq` 0.4.5 establishes an exec/log websocket by having its Req adapter
answer a synthetic `101` and **cast** the real request to a connection process.
When the upgrade is then rejected — a Pod reaped mid-session answers 404, a wrong
container name 400, an unsupported subprotocol 403 — that process stops
abnormally, and OTP's crash report includes its last message: the cast, carrying
the whole `%Req.Request{}`.

That struct holds the kubeconfig. Measured against a live cluster:

- with a **certificate** kubeconfig, `:connect_options` carries
  `cert: <<48, 130, …>>` — client-certificate DER, in a ~2 KB `:error` line;
- with a **token** kubeconfig — the in-cluster ServiceAccount posture, i.e.
  production — `Req`'s `Inspect` implementation redacts the `authorization`
  header, but `options.kubeconfig.current_user["token"]` prints **in full**.

A failed upgrade is an ordinary event, so this is a credential reaching the log
on a normal day. `CrowdControl.LogRedactor` is a `:logger` primary filter,
installed at application start, that replaces the request term, the process state
and the client info with `:redacted_by_crowd_control` — and *only* for reports
that actually carry a `%Req.Request{}` or a Kubereq.Connect state, so other
libraries' crash reports pass through untouched. It never drops an event: the
reason, the process name and the stacktrace survive, because suppressing a crash
report would trade a credential leak for an invisible failure.

Verified on a live cluster: the report now reads
`Last message: :redacted_by_crowd_control`.

Opt out with `config :crowd_control, redact_logs: false` if you install your own
filter. The return path is separately bounded — see
`CrowdControl.Backend.Kubernetes.API`'s exception_reason/1, which keeps the same
material out of the error *term*.

## Sandbox agent transport

`CrowdControl.Backend.Sandboxd` drives a CLI over HTTP to `sandboxd`, an OTP
release running *inside* the sandbox, and `CrowdControl.Provider` owns the
substrate underneath it. It is opt-in and additive: `Backend.Docker`'s
FIFO/`tee` path is unchanged, works with any image that has `sh` and `tail`, and
is not deprecated.

**The bearer token authenticates external callers, and grants in-sandbox code
nothing it does not already have.** This is the single most important thing to
understand about the design. The token is in the agent's own environment, and
the untrusted party *is* the CLI the agent runs — it can read
`CC_SANDBOXD_TOKEN` from `/proc/self/environ` whenever it likes. The token
exists so that nothing *else* which can reach the agent's port can drive the
CLI. It is not a sandbox escape control, and treating it as one would be a
mistake.

**No agent port is ever routable.** Docker and Compose publish it on
`127.0.0.1` only; GCE binds it to the VM's loopback and reaches it through an
SSH tunnel. `HostIp: "127.0.0.1"` is sent explicitly on every port binding,
because omitting it makes Docker publish **two** bindings, IPv4 and IPv6, on
every interface — a one-word omission that turns a loopback port into a public
remote-exec endpoint.

**Nothing secret is persisted.** The token is derived, never stored:

    token = Base.url_encode64(:crypto.mac(:hmac, :sha256, secret, session_key), padding: false)

`session_key` is already in `CrowdControl.Store`, so reattach recomputes the
token with nothing at rest. `Store.secret_keys/0` lists `:sandboxd_secret` and
`:gce_config` so a stray copy in caller opts is stripped anyway, and
`Backend.Sandboxd.scrub/1` drops the endpoint **wholesale** rather than
field-by-field, so a future field on it cannot leak by omission. Persisting the
token instead would have made reattach trivial and put a live credential in
DETS; deriving it is strictly better, at one documented cost: **rotating
`:sandboxd_secret` fails reattach closed** with
`{:error, {:sandboxd, :unauthorized}}` for every sandbox started under the old
secret. That is the intended trade, and the integration suite asserts it.

**Comparison is constant-time** (`Plug.Crypto.secure_compare/2`) and `401`
responses have an empty body. A distinct message for "no header" versus "wrong
token" tells an attacker which half to work on, and a byte-wise comparison leaks
the token to anything that can time responses — which, for a loopback-published
port, is every process on the host.

**`GET /v1/health` is unauthenticated, and returns `{"ok": true}` and nothing
else.** A provider must poll it *before* any token round trip can have
succeeded, so it cannot require a credential. It therefore leaks nothing: no
exec state, no byte counts, no version, no capture path. Anything that can reach
the port learns only that something is listening.

**Environment variables arrive in a request body and are never logged.** Never a
query string, which lands in access and proxy logs. Inside the sandbox they are
written to a `0600` file in a `0700` directory and sourced by a wrapper that
`rm`s the file and `exec`s the CLI through `"$@"`, so nothing but the values
themselves ever needs quoting and no secret enters argv. `ps` works inside a
sandbox and the code running there is model-driven; the integration suite greps
the sandbox's own `ps` output to keep this honest.

**`PUT /v1/files` rejects traversal rather than normalizing it.** Both sides
check: `Backend.Sandboxd.API.safe_path/1` client-side and the agent's router
server-side. That is not redundancy — the client-side check is the only reason a
caller gets a comprehensible error, and the server-side check is the only one
that holds against a caller which is not this library. A request for
`/v1/files/../../etc/passwd` is refused with `400`; a legitimate absolute path
never needs `..` to express itself. The route exists solely so `Agent.Omp`'s
`:agent_dir` obligation is satisfiable on a remote sandbox. General workspace
push/pull remains out of scope.

### The Docker provider

**REGRESSION: `CrowdControl.Provider.Docker` does not block egress, and cannot.**
This is measured, not conceded:

> On one container, `Internal: true` and a published port are mutually
> exclusive. Publishing requires at least one *non-internal* endpoint, and
> attaching one restores full internet egress.

Confirmed six independent ways against Docker 29.4.0 — internal-only,
`NetworkMode: "none"`, two internal networks, `Internal` combined with each of
the four `gateway_mode_ipv4` values, and publish-then-disconnect. The failure is
**silent**: `create` answers `201` with `"Warnings": []` and
`HostConfig.PortBindings` echoes the request verbatim, while
`NetworkSettings.Ports` reads `{"8080/tcp": null}`. The provider therefore
treats "requested a binding, got no usable `HostPort`" as a hard error at
`acquire/1`, because the daemon will never say so.

So `:egress` is **required and never inferred**, exactly as `Backend.Docker`
requires an explicit `:network_mode`:

- `egress: :allow` — a private per-sandbox bridge with full outbound access.
  Correct when the sandbox is *meant* to reach an API, and honest about it.
- `egress: :no_nat` — the same bridge with
  `com.docker.network.bridge.enable_ip_masquerade=false`. **A weaker claim than
  it sounds.** The internet becomes unreachable only because return traffic has
  no SNAT; the Docker host, every container on every other Docker network, and
  Docker's embedded DNS all stay reachable. Packets still leave with a private
  source address, so on a network whose router knows a path back to the
  container subnet, egress is not guaranteed to fail. It is "no NAT", not
  "dropped".

A naive "DNS fails, therefore no egress" test reports the *opposite* of the
truth under `:no_nat` — embedded DNS keeps resolving public names. Egress was
verified by IP literal throughout.

If you need a strong egress block *and* a reachable agent, use the Compose
provider. It takes a second container to get both.

### The Compose provider

`CrowdControl.Backend.Docker` refuses to infer `:network_mode` because `bridge`
grants general outbound access and makes an egress proxy advisory rather than
enforcing. `CrowdControl.Provider.Compose` does not need that gate, and the
reason is structural rather than a matter of better defaults: **there is no
`bridge` for the caller to choose.** The provider creates the sandbox's network
itself, per session, and destroys it with the session. The sandbox is attached
to exactly one network, `<project>-sbx`, created with `Internal: true` — no
default route exists at all, so the internet, the Docker host, every container
on every other Docker network, and Docker's embedded DNS forwarder are
unreachable structurally, not by a missing NAT rule. A caller cannot name a
wider network, because the option to name one does not exist.

The proxy is therefore enforcing rather than advisory for this provider, and
the `bridge`-defeats-the-proxy failure mode is not reachable.

What *is* reachable, and must be stated:

**A sidecar with `egress: :allow` is the sanctioned hole.** It is attached to
`<project>-egress`, a plain NAT bridge, *in addition* to the internal network,
so it can relay the internet into the sandbox. That is precisely what an egress
proxy is for. `:egress` is required on every sidecar and has no default —
omitting it returns `{:error, {:compose, {:egress_required, name}}}`, the same
discipline as `{:docker, :network_mode_required}`. The sandbox itself can never
carry `:allow`: `{:error, {:compose, :sandbox_egress_forbidden}}`. The NAT
bridge is created only if some sidecar asks; if none does, it does not exist.

**The forwarder is the blast radius.** Reaching the agent from the host requires
a published port, and a published port requires a non-internal endpoint — the
constraint described under the Docker provider above. So the provider puts a
second, minimal container — `socat TCP-LISTEN:<port>,fork,reuseaddr
TCP:<sandbox-alias>:<port>` — on both the internal network and a publishing
bridge. That container is dual-homed and is the only part of the stack the host
can reach. It is always synthesized, never caller-supplied: a caller-supplied
forwarder command is exactly how a single-slot `busybox nc -e` gets back in, and
that drops connections while a session holds a chunked stream open. `socat` with
`fork,reuseaddr` was verified against a live daemon at 12 concurrent requests,
12/12 served.

Its publishing network, `<project>-pub`, is created with
`com.docker.network.bridge.enable_ip_masquerade=false`, so **the forwarder has
no internet either** (verified: TCP to `1.1.1.1:443` blocked from inside it).
That is not configurable; it is the property that keeps the stack's claim
strong. The documented limits of `enable_ip_masquerade=false` apply to the
forwarder and to nothing else in the stack: it is "no NAT", not "dropped". The
forwarder runs `socat` and no attacker-controlled code, which is why that weaker
posture is acceptable there and would not be for the sandbox.

**Credentials.** With `:proxy_service` named, the provider mints a per-session
token, sets `ANTHROPIC_BASE_URL` to the proxy's network alias and
`ANTHROPIC_API_KEY` to that token in the sandbox's environment via
`CrowdControl.Backend.Credentials.apply_credentials/2`, and **removes** any real
`:api_key` rather than overriding it. The proxy receives `CC_SESSION_TOKEN` and
the real `ANTHROPIC_API_KEY`. A proxy declared without `egress: :allow` is
refused with `{:error, {:compose, {:proxy_needs_egress, name}}}`, because a
proxy that cannot reach the upstream API fails inside the sandbox as if the
model's own request were at fault. With no `:proxy_service`, an `:api_key` is
passed into the sandbox environment unchanged — the honest no-proxy posture.
Neither `:api_key` nor `:session_token` survives `scrub/1` into a Store record,
and `Provider.Compose.scrub/1` additionally strips `:env` out of every persisted
service spec, which `Store.scrub_opts/1` cannot see into.

**`network: [internal: false]`** is accepted and gives the sandbox a NAT bridge
with full internet. It is the one option that discards everything above, so it
exists only as an explicit, typed-out act; it is never a default and is never
inferred.

### The GCE provider

`CrowdControl.Provider.Gce` runs a sandbox on a Compute Engine spot VM.

**Default posture: `external_ip: true`, with the agent bound to `127.0.0.1` and
reachable only through an SSH tunnel.** Port 22 is the only thing reachable, and
only from whatever firewall rule the operator has. Note that `gcp_compute`'s own
`:external_ip` default is `true`, so a provider that simply forgets this option
ships **publicly addressable sandbox VMs** — the default is stated explicitly
here for that reason, not because it is the most hardened choice.

`external_ip: false` is the hardened mode. It requires same-VPC connectivity to
reach port 22 — no pure-Elixir IAP tunnel client exists, verified, and
`gcloud compute start-iap-tunnel` is not something this library will shell out
to — plus Cloud NAT for the image and CLI fetch.

**The SSH key is per-session, ephemeral, and never touches disk.** An ed25519
keypair is generated in memory and supplied through a custom `key_cb`;
`save_accepted_host` is disabled so nothing can write `known_hosts`. It is set as
**instance-level** `metadata["ssh-keys"]`, never project-wide, because a
project-wide key would apply to every VM in the project. `gcp_compute` has no
`setMetadata` wrapper, so keys are create-time only and cannot be rotated on a
live VM: a session that loses its key destroys and reprovisions, which is the
right answer for a disposable spot VM.

**GCE metadata is readable by in-sandbox code.** Stating it plainly rather than
hiding it: anything in `metadata["cc-sandboxd-token"]` is readable from inside
the VM via the metadata server. That is acceptable for exactly the reason the
token is acceptable at all — see the top of this section — but it means metadata
must not be used for anything the CLI is not already entitled to. In particular
no secret is interpolated into the startup script body, and the `sandboxd`
release fetch verifies a **mandatory** SHA-256.

**REGRESSION vs Docker: a leaked VM bills forever.** The reaper is BEAM-side, so
if the node dies mid-`acquire/1` nothing local knows the VM exists. The backstop
is server-side and needs no BEAM: `max_run_duration` plus
`instanceTerminationAction: DELETE`, set at create time. Label-scoped
`list_live/1` sweeps handle the rest, and `list_live/1` paginates exhaustively
because a truncated page would make the reaper prune *live* sandboxes.

**GCE labels reject `.`**, so the Docker label keys cannot be reused:
`crowd_control-session` and `crowd_control-owner-hash` (a SHA-256 prefix, the
same trick `Backend.Kubernetes` uses because `nonode@nohost` is an illegal label
value) with the raw owner in metadata.

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
