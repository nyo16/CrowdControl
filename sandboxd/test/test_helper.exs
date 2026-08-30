# `mix test` runs with --no-start (see mix.exs aliases): Sandboxd.Application
# refuses to boot without CC_SANDBOXD_TOKEN, and that is a property to keep, not
# to work around. The dependency applications the tests genuinely need are
# started here; the sandboxd application itself is started only by the tests
# that are about starting it.
{:ok, _} = Application.ensure_all_started(:net_runner)
{:ok, _} = Application.ensure_all_started(:bandit)
{:ok, _} = Application.ensure_all_started(:jason)

ExUnit.start()
