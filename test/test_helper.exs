# Docker and Kubernetes integration tests need a live daemon or cluster, so
# they are excluded by default and the ordinary suite stays hermetic. Run them
# with:
#
#     mix test --include docker
#     mix test --include k8s
#
ExUnit.configure(exclude: [:docker, :k8s])
ExUnit.start()
