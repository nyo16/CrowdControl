defmodule CrowdControl.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nyo16/CrowdControl"

  def project do
    [
      app: :crowd_control,
      version: @version,
      # Bumped from ~> 1.18 for :gcp_compute, which declares ~> 1.19. A
      # Version.match?/2 guard in this file would have kept the 1.18 lower bound
      # nominally alive while leaving the GCE provider untested there, and an
      # untested bound is a claim rather than a guarantee.
      elixir: "~> 1.19",
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
      # :ssh is an OTP application rather than a Hex dep, so it cannot be made
      # `optional: true` the way :req and :kubereq are. Naming it here is the
      # only way to get two things: a release that actually contains it (an
      # undeclared OTP app is simply absent, and the failure surfaces at runtime
      # on a customer's VM), and a compiler that can see
      # `:ssh_client_key_api` — CrowdControl.Provider.Gce.Tunnel implements that
      # behaviour, and its callback arities are exactly the thing that is easy to
      # get wrong (`is_host_key/4` vs `/5`, `add_host_key/3` vs `/4`).
      #
      # The cost, stated plainly: :ssh now starts for every consumer, including
      # those who never touch the GCE provider. It is a small supervisor tree
      # that listens on nothing unless a daemon is explicitly started, which is
      # a better trade than dropping `@behaviour` to silence five warnings and
      # losing the arity check that S0.3 showed was needed.
      extra_applications: [:logger, :ssh],
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
    "Orchestrate many Claude Code, Open Code, and omp CLI instances in parallel from Elixir, " <>
      "with zero-zombie subprocess management, structured JSON/RPC I/O, and Docker hardening."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
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
        Agents: [
          CrowdControl.Agent,
          CrowdControl.Agent.ClaudeCode,
          CrowdControl.Agent.Omp
        ],
        Backends: [
          CrowdControl.Backend,
          CrowdControl.Backend.Local,
          CrowdControl.Backend.Docker,
          CrowdControl.Backend.Kubernetes,
          CrowdControl.Backend.Sandboxd
        ],
        Providers: [
          CrowdControl.Provider,
          CrowdControl.Provider.Endpoint,
          CrowdControl.Provider.Docker,
          CrowdControl.Provider.Compose,
          CrowdControl.Provider.Gce
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
          CrowdControl.Backend.Credentials,
          CrowdControl.Backend.Docker.API,
          CrowdControl.Backend.Docker.Demux,
          CrowdControl.Backend.Docker.HostConfig,
          CrowdControl.Backend.Kubernetes.API,
          CrowdControl.Backend.Sandboxd.API,
          CrowdControl.Provider.Gce.API,
          CrowdControl.Provider.Gce.Tunnel,
          CrowdControl.Provider.Gce.Startup
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
      #
      # `~> 0.5` is `>= 0.5.0 and < 1.0.0`, so it already admits the 0.7 that
      # kubereq and gcp_compute now require. Docker works across all of them, and
      # narrowing it would break Docker-only users for no reason.
      {:req, "~> 0.5", optional: true},
      # Optional for the same reason as :req, and behind the same trade: only
      # CrowdControl.Backend.Kubernetes needs it. 0.4.5 is a floor, not a
      # preference: 0.4.4 pins `req ~> 0.6.0`, which cannot coexist with
      # gcp_compute's `req ~> 0.7`.
      #
      # 0.4.5 also changed the exec/log model — its Req adapter answers a
      # synthetic 101 and casts the real request to the connection process, so a
      # rejected upgrade is reported *asynchronously* and its crash report
      # carries the whole %Req.Request{}. Both consequences are handled:
      # CrowdControl.Backend.Kubernetes.API normalizes the async failure, and
      # CrowdControl.LogRedactor keeps the kubeconfig out of the log.
      {:kubereq, "~> 0.4.5", optional: true},
      # Optional, and only CrowdControl.Provider.Gce needs it. 0.3.0 is a floor:
      # 0.2.0 could not complete a single launch against real GCP (every bodyless
      # POST was rejected 411 for want of a Content-Length), and it is the release
      # that requires `req ~> 0.7` for the `:decoders` hook. goth stays optional
      # inside it, so this still adds no runtime dep the tree lacks. It is also
      # the reason the Elixir lower bound moved to ~> 1.19.
      {:gcp_compute, "~> 0.3", optional: true},
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
