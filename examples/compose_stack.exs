# A per-session Docker *stack* rather than a single container: an internal-only
# sandbox plus one egress-proxy sidecar. Demonstrates
# `CrowdControl.Provider.Compose`. No `docker compose` binary is involved; the
# provider synthesises the Engine API calls itself.
#
#   CC_SANDBOXD_SECRET=... CC_EGRESS_PROXY_IMAGE=... mix run examples/compose_stack.exs
#
# The network shape, which is the whole reason this needs two containers:
#
#   * the sandbox sits on an `Internal: true` network and *only* there, so it
#     has no default route at all -- the internet, the Docker host, every other
#     Docker network and Docker's own embedded DNS are unreachable structurally
#     rather than by a missing NAT rule;
#   * a **forwarder sidecar is synthesised automatically** (alpine/socat by
#     default), dual-homed on that network and a publish-only bridge, so the
#     agent port is still reachable on 127.0.0.1 without handing the sandbox a
#     way out. You do not declare it, and must not name a service after it;
#   * the proxy below is the one service allowed to declare `egress: :allow`,
#     which is what lets the CLI reach the Anthropic API at all.
#
# Prerequisites: everything examples/sandboxd_docker.exs needs, plus a
# conforming egress proxy image. **None ships with this library** -- SECURITY.md
# "Egress proxy contract" specifies what one must do (inject the real key
# server-side, enforce a per-session budget, restrict destinations). Point
# CC_EGRESS_PROXY_IMAGE at yours; it must serve HTTP on 8080 and answer
# /healthz, or adjust `:port` and `:ready` below to match it.

Application.put_env(
  :crowd_control,
  :sandboxd_secret,
  System.fetch_env!("CC_SANDBOXD_SECRET")
)

image = System.get_env("CC_SANDBOX_IMAGE", "crowd_control/sandbox:dev")
proxy_image = System.fetch_env!("CC_EGRESS_PROXY_IMAGE")

proxy = %{
  name: "proxy",
  image: proxy_image,
  # Required on every sidecar, and there is no default. A sidecar with :allow
  # is also attached to the NAT bridge and can relay the internet into the
  # sandbox -- which is exactly what an egress proxy is for, and exactly why
  # saying so is mandatory. Omitting it is
  # {:error, {:compose, {:egress_required, "proxy"}}}.
  egress: :allow,
  env: %{"LOG_LEVEL" => "info"},
  volumes: [%{name: "proxy-state", target: "/var/lib/proxy"}],
  # Only read because this service is named by :proxy_service below; it is the
  # port the sandbox's ANTHROPIC_BASE_URL is built from.
  port: 8080
}

provider = [
  image: image,
  services: [proxy],
  # Every mount must name a volume declared here. Created as
  # <project>-proxy-state, and destroyed with the stack.
  volumes: [%{name: "proxy-state"}],
  # Gate the stack on the proxy being up, so the first request does not race
  # the proxy's boot and surface as if the model had failed.
  ready: %{
    "proxy" => %{
      test: ["CMD-SHELL", "wget -q -O- http://127.0.0.1:8080/healthz || exit 1"],
      interval_ms: 1_000,
      retries: 20
    }
  },
  proxy_service: "proxy",
  health_timeout: 60_000,
  # Hardening applies to every container in the stack; there are deliberately
  # no per-service overrides.
  cpus: 2.0,
  memory: 2 * 1024 * 1024 * 1024,
  ready_timeout: 60_000
]

result =
  CrowdControl.run("In one sentence: what is OTP?",
    # Naming :proxy_service above means this key is *removed* from the
    # sandbox's environment rather than overridden: the sandbox gets
    # ANTHROPIC_BASE_URL pointing at the proxy's network alias plus a
    # per-session token, and the proxy gets CC_SESSION_TOKEN and the real key.
    api_key: System.fetch_env!("ANTHROPIC_API_KEY"),
    timeout: 120_000,
    backend: {CrowdControl.Backend.Sandboxd, provider: {CrowdControl.Provider.Compose, provider}}
  )

case result do
  {:result, "success", r} ->
    IO.puts(r["result"])
    IO.puts("(#{r["num_turns"]} turn(s))")

  {:result, subtype, r} ->
    IO.puts("failed (#{subtype}): #{inspect(r["result"])}")

  {:error, reason} ->
    IO.puts("""
    the stack never came up: #{inspect(reason)}

    Usual causes: no Docker daemon on DOCKER_HOST, #{image} or #{proxy_image}
    does not exist, or the proxy never reported healthy -- a sandbox with no
    route out cannot reach the API without it.
    """)
end
