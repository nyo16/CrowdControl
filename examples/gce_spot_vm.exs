# ############################################################################
# # BILLABLE. This script creates a real Google Compute Engine spot VM in your
# # project and you are charged for it. There is no dry-run mode.
# ############################################################################
#
# One VM per sandbox, running `sandboxd`, reached through an SSH tunnel to the
# VM's loopback. Demonstrates `CrowdControl.Provider.Gce`. No `gcloud` and no
# IAP client are involved at runtime.
#
#   CC_GCE_CONFIRM=yes \
#   GCP_PROJECT=my-project \
#   GCP_ACCESS_TOKEN=$(gcloud auth print-access-token) \
#   CC_SANDBOXD_URL=https://.../sandboxd-linux-amd64.tar.gz \
#   CC_SANDBOXD_SHA256=$(cut -d' ' -f1 sandboxd-linux-amd64.tar.gz.sha256) \
#   CC_SANDBOXD_SECRET=... \
#     mix run examples/gce_spot_vm.exs
#
# CC_GCE_CONFIRM is this script's own guard, not the library's: a mistyped
# `mix run` should not spend money.
#
# Prerequisites:
#
#   * `{:gcp_compute, "~> 0.2"}` in your deps. It is `optional: true` here, so
#     an application that wants this provider must depend on it directly. The
#     OTP `:ssh` application is already declared by this library.
#
#   * GCP credentials. The static token below is the shortest honest path for a
#     one-shot script -- `gcloud auth print-access-token` expires in about an
#     hour. In production pass a Goth-backed `:token_provider`, or a ready
#     `%GcpCompute.Config{}` as `:gce_config`.
#
#   * IAM on the project: instances create/get/list/delete plus the zone
#     operation polls, which `roles/compute.instanceAdmin.v1` covers. Add
#     `roles/iam.serviceAccountUser` only if you pass `:service_account` --
#     this example deliberately does not, because with a service account
#     attached the sandboxed CLI can mint project credentials from the
#     metadata server.
#
#   * a published `sandboxd` release tarball and its SHA-256. CI publishes
#     `sandboxd-linux-{amd64,arm64}.tar.gz` with a `.sha256` sidecar; pick the
#     one matching `:machine_type`'s architecture, since an OTP release only
#     runs on the glibc and CPU it was built for. `:sandboxd_sha256` is
#     **mandatory** and never skipped: "no checksum configured" and "checksum
#     verified" must not be the same code path. A mismatch means the archive is
#     never extracted, so the agent never answers health, so `acquire/1`
#     deletes the VM.
#
#   * `config :crowd_control, sandboxd_secret: ...`, as in
#     examples/sandboxd_docker.exs. For a *different* node to reattach later,
#     also put the client config where it can find it, since the persisted
#     record deliberately carries no credentials:
#
#       config :crowd_control, gce: [project: "my-project", zone: "us-central1-a"]
#
# Two numbers worth understanding before you run this:
#
#   * `:max_run_duration` is a **server-side** deadline. Combined with spot's
#     instanceTerminationAction: DELETE it deletes the VM even if this BEAM
#     node dies mid-acquire, when nothing local ever knew the VM existed and
#     CrowdControl.Reaper will never see it. There is no "off": a long-lived
#     sandbox passes a large number. An explicit value below
#     `:ready_timeout` + 5 minutes is refused.
#
#   * `:ready_timeout`'s 180_000 ms default is **measured**, not reasoned. On a
#     spot e2-small in us-central1-a with no bootstrap script: 8.9s to the insert
#     operation reporting DONE, 0.0s more to RUNNING-with-an-address, 23.8s for
#     sshd to accept and forward, 7.3s for the agent to answer /v1/health —
#     31.1s inside the timeout's window, 39.9s end to end. The default is ~6x
#     that because a bootstrap script is what actually costs time. Attach to
#     [:crowd_control, :gce, :phase] to measure your own image instead of
#     guessing.

if System.get_env("CC_GCE_CONFIRM") != "yes" do
  IO.puts("""
  Refusing to run: this example creates a billable GCE spot VM.

  Re-run with CC_GCE_CONFIRM=yes once you are ready to be charged.
  """)

  System.halt(1)
end

Application.put_env(
  :crowd_control,
  :sandboxd_secret,
  System.fetch_env!("CC_SANDBOXD_SECRET")
)

# The bare sandbox needs 31s (measured, above). This example adds a node install
# plus `npm install -g` on a cold apt cache, which is minutes rather than
# seconds and is the only reason this is not the 180_000 default. Raise it rather
# than discovering it as a health timeout on a VM that is already billing.
ready_timeout = 420_000

# Runs as root *before* the agent is installed, which is load-bearing:
# GET /v1/health is the provider's only readiness signal, so bootstrapping
# first makes a healthy agent imply a finished bootstrap. Reversed, the
# session's first exec would fail on a sandbox that looked ready.
bootstrap = """
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
npm install -g @anthropic-ai/claude-code
"""

provider = [
  project: System.fetch_env!("GCP_PROJECT"),
  zone: System.get_env("GCP_ZONE", "us-central1-a"),
  token_provider: {GcpCompute.TokenProvider.Static, System.fetch_env!("GCP_ACCESS_TOKEN")},
  sandboxd_url: System.fetch_env!("CC_SANDBOXD_URL"),
  sandboxd_sha256: System.fetch_env!("CC_SANDBOXD_SHA256"),
  bootstrap_script: bootstrap,
  machine_type: "e2-standard-2",
  source_image: "projects/debian-cloud/global/images/family/debian-12",
  disk_size_gb: 20,
  spot: true,
  # sandboxd binds the VM's loopback, so TCP 22 is the only reachable port and
  # the agent is reachable only through this node's SSH tunnel. Note that the
  # default VPC allows 0.0.0.0/0 on 22: pass :tags and attach your own firewall
  # rule if a publickey-only internet-facing sshd is not acceptable.
  # `external_ip: false` is the hardened mode, and needs same-VPC connectivity
  # from this node plus Cloud NAT.
  external_ip: true,
  ready_timeout: ready_timeout,
  # 30 minutes. Must be at least ready_timeout / 1000 + 300.
  max_run_duration: 1_800
]

result =
  CrowdControl.run("In one sentence: what is OTP?",
    api_key: System.fetch_env!("ANTHROPIC_API_KEY"),
    timeout: 300_000,
    backend: {CrowdControl.Backend.Sandboxd, provider: {CrowdControl.Provider.Gce, provider}}
  )

case result do
  {:result, "success", r} ->
    IO.puts(r["result"])
    IO.puts("(#{r["num_turns"]} turn(s))")

  {:result, subtype, r} ->
    IO.puts("failed (#{subtype}): #{inspect(r["result"])}")

  {:error, reason} ->
    IO.puts("""
    the VM never became healthy: #{inspect(reason)}

    It has already been deleted -- every failure on the acquire path rolls the
    instance back, and max_run_duration is the backstop if this node dies too.
    Usual causes: missing IAM, an expired GCP_ACCESS_TOKEN, a CC_SANDBOXD_SHA256
    that does not match the tarball, or a bootstrap slower than ready_timeout.
    """)
end
