# Run a CLI inside a per-session Docker container, driven over HTTP by the
# `sandboxd` agent instead of through a FIFO. Demonstrates the `:backend`
# option with `CrowdControl.Backend.Sandboxd` and `CrowdControl.Provider.Docker`.
#
#   CC_SANDBOXD_SECRET=... mix run examples/sandboxd_docker.exs
#
# Prerequisites:
#
#   * the optional `:req` dependency and a reachable Docker daemon;
#
#   * a stable agent secret. Every sandbox's bearer token is derived from it
#     rather than persisted, so it must survive restarts or reattach fails
#     closed with {:sandboxd, :unauthorized}:
#
#       config :crowd_control, sandboxd_secret: System.fetch_env!("CC_SANDBOXD_SECRET")
#
#     Set from the environment below so this script runs as-is;
#
#   * an image whose entrypoint is the sandboxd release. This repo builds one:
#
#       docker build --target sandbox-dev -t crowd_control/sandbox:dev .
#
#     That target carries the agent and nothing else, which is what exercises
#     the transport. A sandbox that also has to *run* Claude Code needs the CLI
#     on PATH as well:
#
#       FROM crowd_control/sandbox:dev
#       USER root
#       RUN apt-get update && apt-get install -y --no-install-recommends nodejs npm \
#        && npm install -g @anthropic-ai/claude-code
#       USER crowdctl
#
#     Build that and point CC_SANDBOX_IMAGE at it.

Application.put_env(
  :crowd_control,
  :sandboxd_secret,
  System.fetch_env!("CC_SANDBOXD_SECRET")
)

image = System.get_env("CC_SANDBOX_IMAGE", "crowd_control/sandbox:dev")

provider = [
  image: image,
  # Required, and there is no default: this provider cannot both publish the
  # agent port and block egress, because on one container `Internal: true` and
  # a published port are mutually exclusive. So the posture is written down
  # rather than guessed. `:no_nat` is the other value -- it drops the internet
  # but still reaches the Docker host and every other Docker network, so it is
  # not isolation. For a structural egress block see examples/compose_stack.exs.
  egress: :allow,
  # Hardening beyond the CapDrop / no-new-privileges / PidsLimit defaults,
  # shared verbatim with CrowdControl.Backend.Docker.
  cpus: 2.0,
  memory: 2 * 1024 * 1024 * 1024,
  pids_limit: 256,
  ready_timeout: 60_000
]

result =
  CrowdControl.run("In one sentence: what is OTP?",
    api_key: System.fetch_env!("ANTHROPIC_API_KEY"),
    timeout: 120_000,
    backend: {CrowdControl.Backend.Sandboxd, provider: {CrowdControl.Provider.Docker, provider}}
  )

case result do
  {:result, "success", r} ->
    IO.puts(r["result"])
    IO.puts("(#{r["num_turns"]} turn(s))")

  {:result, subtype, r} ->
    IO.puts("failed (#{subtype}): #{inspect(r["result"])}")

  {:error, reason} ->
    IO.puts("""
    the sandbox never came up: #{inspect(reason)}

    Usual causes: no Docker daemon on DOCKER_HOST, the #{image} image does not
    exist, or its entrypoint is not the sandboxd release.
    """)
end
