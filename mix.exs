defmodule Arcana.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/georgeguimaraes/arcana"

  def project do
    [
      app: :arcana,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),

      # Docs
      name: "Arcana",
      description: "RAG (Retrieval Augmented Generation) library for Elixir",
      source_url: @source_url,
      docs: docs()
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "guides/getting-started.md",
        "guides/llm-integration.md",
        "guides/agentic-rag.md",
        "guides/reranking.md",
        "guides/search-algorithms.md",
        "guides/evaluation.md",
        "guides/dashboard.md"
      ],
      groups_for_extras: [
        Guides: ~r/guides\/.*/
      ],
      groups_for_modules: [
        Core: [Arcana, Arcana.Document, Arcana.Chunk],
        Utilities: [Arcana.Rewriters, Arcana.Chunker],
        Embeddings: [Arcana.Embeddings.Serving],
        "LiveView UI": [ArcanaWeb.DashboardLive]
      ]
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
      {:text_chunker, "~> 0.3"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},

      # Optional: Dashboard UI
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:phoenix_html, "~> 4.1", optional: true},
      {:floki, "~> 0.36", only: :test},
      {:lazy_html, "~> 0.1.8", only: :test},

      # Optional: Enhanced installer
      {:igniter, "~> 0.5", optional: true},

      # LLM integrations via Req.LLM
      {:req_llm, github: "georgeguimaraes/req_llm", ref: "781b623a3621175bf1e3f24e2c44e6eb1982608b"},

      # Optional: In-memory vector store with HNSW
      {:hnswlib, github: "elixir-nx/hnswlib", optional: true},
      {:elixir_make, "~> 0.9", override: true}
    ]
  end
end
