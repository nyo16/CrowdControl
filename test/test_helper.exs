# Docker and Kubernetes integration tests need a live daemon or cluster, the omp
# provider tests need the `omp` binary plus a loopback socket, and the sandboxd,
# compose and gce tests need a live substrate — so they are excluded by default
# and the ordinary suite stays hermetic. Run them with:
#
#     mix test --include docker
#     mix test --include k8s
#     mix test --include omp
#
#     # needs `docker build --target sandbox-dev -t crowd_control/sandbox:dev .`
#     mix test --include sandboxd
#     mix test --include compose
#
#     # billable: creates a real spot VM. Needs GCP credentials; see gce_test.exs.
#     mix test --include gce
#
ExUnit.configure(exclude: [:docker, :k8s, :omp, :sandboxd, :compose, :gce])

# One agent secret for the whole suite.
#
# `CrowdControl.Provider.token/1` derives every sandbox's bearer token from
# application config, which is global mutable state. Modules that each set their
# own secret in `setup` therefore race: module A configures secret X, module B
# overwrites it with Y, and a token A derived under X no longer validates —
# surfacing as an intermittent 401 in whichever test happens to lose. That was
# observed as a flaky GCE tunnel failure, roughly one run in three.
#
# Setting it once here means no module needs to touch it, so those modules stay
# `async: true`. The only test module that legitimately mutates it is
# `provider_test.exs`, which tests rotation and absence themselves, and it is
# `async: false` for exactly that reason.
Application.put_env(:crowd_control, :sandboxd_secret, "test-suite-sandboxd-secret-32-bytes!!")

ExUnit.start()
