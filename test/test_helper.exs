# Docker and Kubernetes integration tests need a live daemon or cluster, and
# the omp provider tests need the `omp` binary plus a loopback socket, so they
# are excluded by default and the ordinary suite stays hermetic. Run them with:
#
#     mix test --include docker
#     mix test --include k8s
#     mix test --include omp
#
ExUnit.configure(exclude: [:docker, :k8s, :omp])
ExUnit.start()
