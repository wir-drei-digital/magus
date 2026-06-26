defmodule Magus.MixProject do
  use Mix.Project

  def project do
    [
      app: :magus,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Magus.Application, []},
      extra_applications: [:logger, :runtime_tools, :os_mon]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, "test.e2e": :test, "test.e2e.live": :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support", "test/e2e_live/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:fast_rss, "~> 0.5"},
      {:mdex_katex, "~> 0.1"},
      {:mdex_mermaid, "~> 0.3"},
      {:tidewave, "~> 0.5", only: [:dev]},
      {:kreuzberg, "~> 4.4"},
      {:ex_aws_s3, "~> 2.0"},
      {:ex_aws, "~> 2.0"},
      {:hackney, "~> 1.20"},
      {:saxy, "~> 1.6"},
      {:sweet_xml, "~> 0.7"},
      {:floki, "~> 0.37"},
      {:yaml_elixir, "~> 2.11"},
      {:pgvector, "~> 0.3"},
      # Fork carries the generation-id streaming patch (priv/patches/req_llm-surface-generation-id.patch)
      # for OpenRouter usage reconciliation; revert to "~> 1.11" once upstream merges it.
      {:req_llm, github: "flipbug/req_llm", branch: "surface-generation-id", override: true},
      {:jido_action, "~> 2.0"},
      {:jido, "~> 2.0"},
      {:libgraph, "~> 0.16", override: true},
      {:jido_ai, github: "agentjido/jido_ai", branch: "main"},
      {:mdex, "~> 0.7"},
      {:yaml_front_matter, "~> 1.0"},
      {:html_sanitize_ex, "~> 1.4"},
      {:bcrypt_elixir, "~> 3.0"},
      {:cloak, "~> 1.1"},
      {:cloak_ecto, "~> 1.3"},
      {:anubis_mcp, "~> 1.6"},
      {:oidcc, "~> 3.7"},
      {:sprites, git: "https://github.com/superfly/sprites-ex.git"},
      {:picosat_elixir, "~> 0.2"},
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:oban, "~> 2.0"},
      {:open_api_spex, "~> 3.0"},
      {:usage_rules, "~> 0.1", only: [:dev]},
      {:ash_paper_trail, "~> 0.5"},
      {:live_debugger, "~> 0.4", only: [:dev]},
      {:ash_state_machine, "~> 0.2"},
      {:oban_web, "~> 2.0"},
      {:ash_oban, "~> 0.6"},
      {:ash_authentication_phoenix, "~> 2.0"},
      {:ash_authentication, "~> 4.13"},
      {:ash_postgres, "~> 2.0"},
      {:ash_json_api, "~> 1.0"},
      {:ash_typescript, "~> 0.17"},
      {:ash_phoenix, "~> 2.0"},
      {:ash, "~> 3.0"},
      {:igniter, "~> 0.6", only: [:dev, :test], override: true},
      {:phoenix, "~> 1.8.2"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_psql_extras, "~> 0.6"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_test, "~> 0.9", only: :test},
      {:phoenix_test_playwright, "~> 0.10", only: :test},
      {:mox, "~> 1.0", only: :test},
      {:bypass, "~> 2.1", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, ">= 0.26.0", override: true},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:tzdata, "~> 1.1"},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ash_credo, "~> 0.15", only: [:dev, :test], runtime: false},
      {:tiptap_phoenix, github: "wir-drei-digital/tiptap-phoenix"},
      {:redix, "~> 1.5"},
      {:stream_data, "~> 1.1"}
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
      setup: ["deps.get", "ash.setup", "assets.setup", "assets.build", "run priv/repo/seeds.exs"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ash.setup --quiet", "test"],
      "assets.setup": [
        "tailwind.install --if-missing",
        "esbuild.install --if-missing"
      ],
      "assets.build": [
        "compile",
        "tailwind magus",
        "esbuild magus",
        "cmd cp assets/node_modules/pdfjs-dist/build/pdf.worker.min.mjs priv/static/assets/js/"
      ],
      "assets.deploy": [
        "tailwind magus --minify",
        "esbuild magus --minify",
        "cmd cp assets/node_modules/pdfjs-dist/build/pdf.worker.min.mjs priv/static/assets/js/",
        "cmd --cd frontend npm run build",
        "phx.digest"
      ],
      "test.e2e": [
        fn _ -> System.put_env("E2E", "1") end,
        "test --include e2e test/e2e"
      ],
      "test.e2e.live": [
        fn _ -> System.put_env("E2E_LIVE", "1") end,
        "test --include e2e_live test/e2e_live"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "test --exclude e2e"
      ],
      # Compile first so AshCredo's checks that introspect compiled DSL modules
      # resolve instead of emitting "could not load" diagnostics.
      lint: ["compile", "credo --strict"]
    ]
  end
end
