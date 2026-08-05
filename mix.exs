defmodule Hiraeth.MixProject do
  use Mix.Project

  def project do
    [
      app: :hiraeth,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      test_coverage: [tool: ExCoveralls],
      # Mix tasks live under lib/mix/tasks and call Mix API (Mix.shell/0,
      # Mix.Task.run/1, Mix.Task behaviour); :mix is not in dialyxir's default
      # PLT app set, so add it explicitly or dialyzer reports unknown_function.
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Hiraeth.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test,
        "precommit.fast": :test,
        gate: :test,
        "test.fast": :test,
        "test.full": :test,
        ci: :test,
        quality: :test
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.8"},
      {:ash, "~> 3.28"},
      {:ash_postgres, "~> 2.9"},
      {:ash_phoenix, "~> 2.3"},
      {:sourceror, "~> 1.7", only: [:dev, :test]},
      {:simple_sat, "~> 0.1.4"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:logger_json, "~> 7.0", only: [:prod]},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:oban, "~> 2.17"},
      {:credo, "~> 1.7", only: [:dev, :test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test]},
      {:excoveralls, "~> 0.18", only: [:dev, :test]}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind hiraeth", "esbuild hiraeth"],
      "assets.deploy": [
        "tailwind hiraeth --minify",
        "esbuild hiraeth --minify",
        "phx.digest"
      ],
      precommit: ["precommit.fast"],
      "precommit.fast": [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "test.fast"
      ],
      # The ≤5-min blocking gate. Deliberately omits sobelow/hex.audit: they
      # need network and stay in the CI `static` job and deep `ci` lane.
      gate: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "cmd mix credo --strict",
        "test.fast"
      ],
      "test.fast": [
        "test --exclude slow --exclude full_catalog --exclude integration --exclude performance --exclude browser --exclude public_catalog_full"
      ],
      "test.full": ["test"],
      ci: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        # Run the static gates in fresh Mix VMs: `mix credo` starts the credo
        # application (Credo.CLI.main -> Credo.Application.start), so an
        # in-chain step makes the later `mix test` app startup fail with
        # "application credo ... already started" (same class of issue as
        # hex.audit: Mix purges archive tasks once `compile` runs in the
        # same VM, so a bare hex.audit step is lost in-chain).
        "cmd mix credo --strict",
        "cmd mix sobelow --config .sobelow-conf --exit Low",
        "cmd mix hex.audit",
        "assets.setup",
        "assets.build",
        "test.full"
      ],
      quality: ["dialyzer", "coveralls"]
    ]
  end
end
