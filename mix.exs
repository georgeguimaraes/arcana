defmodule Arcana.MixProject do
  use Mix.Project

  @version "1.4.1"
  @source_url "https://github.com/georgeguimaraes/arcana"

  def project do
    [
      app: :arcana,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),

      # Hex
      name: "Arcana",
      description: "RAG (Retrieval Augmented Generation) library for Elixir",
      source_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
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
        "guides/telemetry.md",
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
      {:exla, "~> 0.10", optional: true},
      {:emlx, "~> 0.2", optional: true},
      {:text_chunker, "~> 0.3"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},

      # Optional: Dashboard UI
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:phoenix_html, "~> 4.1", optional: true},
      {:floki, "~> 0.36", only: :test},
      {:lazy_html, "~> 0.1.8", only: :test},
      {:phoenix_ecto, "~> 4.7", only: :test},

      # Optional: Enhanced installer
      {:igniter, "~> 0.5", optional: true},

      # LLM integrations via Req.LLM
      {:req_llm, "~> 1.2"},

      # Optional: In-memory vector store with HNSW
      {:hnswlib, "~> 0.1", optional: true},

      # Community detection for GraphRAG
      {:leidenfold, "~> 0.3", optional: true},

      # Optional: ColBERT-style neural reranking
      {:stephen, "~> 1.0", optional: true}
    ]
  end
end
