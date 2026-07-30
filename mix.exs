defmodule EftBuddy.MixProject do
  use Mix.Project

  def project do
    [
      app: :eft_buddy,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {EftBuddy.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
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
      {:phoenix, "~> 1.8.3"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
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
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:bandit, "~> 1.5"}
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
      "assets.build": ["compile", "tailwind eft_buddy", "esbuild eft_buddy"],
      # `compile` FIRST, and it is load-bearing rather than defensive. LiveView's
      # compiler writes colocated hooks to `_build/<env>/phoenix-colocated/<app>`,
      # and `assets/js/app.js` imports that path — so esbuild cannot resolve it
      # until a compile has happened. `assets.build` above already compiles, which
      # is why local development never hit this; `assets.deploy` is only reached by
      # a production build, and nothing performed one until the container existed.
      # It failed there on the first attempt with "Could not resolve
      # phoenix-colocated/eft_buddy".
      "assets.deploy": [
        "compile",
        "tailwind eft_buddy --minify",
        "esbuild eft_buddy --minify",
        "phx.digest"
      ],
      # The two lock-file audits run FIRST, before `compile`. This is not
      # cosmetic: `hex.audit` is provided by the Hex *archive*, and once
      # `mix compile` has run in the same OS process Mix can no longer resolve
      # it ("** (Mix) The task \"hex.audit\" could not be found"), so the step
      # silently aborted the alias instead of auditing anything. Running it up
      # front also fails faster on a retired or vulnerable dependency, before
      # spending time on a full compile. CI is unaffected either way, since it
      # runs each check as its own process (.github/workflows/ci.yml).
      precommit: [
        "deps.audit",
        "hex.audit",
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "sobelow --exit Low --skip",
        "test"
      ]
    ]
  end
end
