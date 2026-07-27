# Docker integration tests need a live daemon, so they are excluded by default
# and the ordinary suite stays hermetic. Run them with:
#
#     mix test --include docker
#
ExUnit.configure(exclude: [:docker])
ExUnit.start()
