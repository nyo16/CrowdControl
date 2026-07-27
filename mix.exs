defmodule CrowdControl.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nyo16/CrowdControl"

  def project do
    [
      app: :crowd_control,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [
        plt_add_apps: [:mix],
        flags: [:error_handling, :unknown, :missing_return, :extra_return]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {CrowdControl.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "coveralls.github": :test,
        docs: :dev,
        sobelow: :dev,
        "hex.audit": :dev,
        "deps.audit": :dev
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp description do
    "Orchestrate many Claude Code and Open Code CLI instances in parallel from Elixir, " <>
      "with zero-zombie subprocess management, structured stream-json I/O, and Docker hardening."
  end

  defp package do
    [
      licenses: ["MIT"],
      maintainers: ["Niko Maroulis"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md",
        "Security" => "#{@source_url}/blob/master/SECURITY.md"
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE SECURITY.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "SECURITY.md",
        "CONTRIBUTING.md"
      ],
      groups_for_modules: [
        Core: [CrowdControl, CrowdControl.Session],
        Backends: [
          CrowdControl.Backend,
          CrowdControl.Backend.Local,
          CrowdControl.Backend.Docker
        ],
        Persistence: [
          CrowdControl.Store,
          CrowdControl.Store.ETS,
          CrowdControl.Store.DETS,
          CrowdControl.Reaper
        ],
        # CrowdControl.Application is deliberately absent: it is @moduledoc false,
        # so listing it here groups a module that never renders.
        Internal: [
          CrowdControl.CLI,
          CrowdControl.Protocol,
          CrowdControl.Backend.Shell,
          CrowdControl.Backend.Docker.API,
          CrowdControl.Backend.Docker.Demux
        ]
      ]
    ]
  end

  defp deps do
    [
      {:net_runner, "~> 1.2"},
      # Optional: only CrowdControl.Backend.Docker needs it, and the library's
      # one-runtime-dep footprint is worth protecting. Unconditional in :test so
      # CI always exercises the Docker backend's pure paths.
      {:req, "~> 0.5", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:stream_data, "~> 1.1", only: :test},
      {:excoveralls, "~> 0.18", only: :test},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
