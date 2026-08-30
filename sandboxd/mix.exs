defmodule Sandboxd.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :sandboxd,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps(),
      releases: releases()
    ]
  end

  # --no-start because Sandboxd.Application refuses to boot without
  # CC_SANDBOXD_TOKEN, and that fail-closed behaviour is a security property
  # worth keeping rather than weakening for the test environment. test_helper
  # starts the dependency applications it needs, and application_test.exs
  # exercises the real boot path explicitly, both ways.
  defp aliases do
    [test: "test --no-start"]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {Sandboxd.Application, []}
    ]
  end

  # Four deps and nothing else, on purpose. This release is downloaded into a
  # sandbox — often over the network by a GCE startup script — so every
  # kilobyte and every transitive package is part of the attack surface.
  #
  # No :crowd_control dependency, and there never can be one: the parent app
  # depends on this artifact, not the other way round.
  defp deps do
    [
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.16"},
      {:net_runner, "~> 1.2"},
      {:jason, "~> 1.4"}
    ]
  end

  # include_erts: true because the target sandbox image is not guaranteed to
  # have Erlang installed at all — the GCE case fetches this tarball onto a
  # bare Debian VM. A release must be built on the target's glibc, which is why
  # CI builds it inside the same debian-bookworm image the sandbox uses.
  defp releases do
    [
      sandboxd: [
        include_erts: true,
        include_executables_for: [:unix],
        strip_beams: true
      ]
    ]
  end
end
