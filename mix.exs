defmodule Arcana.MixProject do
  use Mix.Project

  def project do
    [
      app: :arcana,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:pgvector, "~> 0.3"},
      {:bumblebee, "~> 0.6"},
      {:nx, "~> 0.9"},
      {:exla, "~> 0.9"},
      {:jason, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},

      # Optional: Dashboard UI
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:phoenix_html, "~> 4.1", optional: true},
      {:floki, "~> 0.36", only: :test},
      {:lazy_html, "~> 0.1", only: :test},

      # Optional: Enhanced installer
      {:igniter, "~> 0.5", optional: true}
    ]
  end
end
