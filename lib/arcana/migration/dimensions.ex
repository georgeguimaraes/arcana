defmodule Arcana.Migration.Dimensions do
  @moduledoc false

  alias Arcana.Migration.SchemaScope

  # Shared by `Arcana.Migration` and `Arcana.Graph.Migration`, which each size
  # an embedding column and each need the same required-option check and the
  # same comparison against what the database already has.
  #
  # It lives here because the first version of this logic was copied between
  # the two modules and drifted immediately: the graph copy told the operator
  # to run `mix arcana.gen.embedding_migration`, which only resizes
  # `arcana_chunks.embedding` and leaves the graph column exactly as it was.
  # The remedy text is a parameter now, so the two can differ on purpose
  # rather than by accident.

  @doc """
  Returns the requested dimension, raising when it is missing or not a
  positive integer.

  Deliberately does not consult the configured embedder:
  `Arcana.Embedder.dimensions/1` falls back to embedding a probe string, so
  defaulting from it would let a migration load a model or call a remote
  service.
  """
  def require!(opts, module, table) do
    case Keyword.get(opts, :dimensions) do
      value when is_integer(value) and value > 0 ->
        value

      nil ->
        raise ArgumentError, """
        #{inspect(module)}.up/1 requires :dimensions.

        It sizes #{table}.embedding, and the column can't be resized later
        without rebuilding every vector in it, so there is no safe default to
        guess.

        Pass the dimension your embedder produces:

            #{inspect(module)}.up(dimensions: 384)

        To find it, ask your embedder outside the migration:

            Arcana.Embedder.dimensions(Arcana.Config.embedder())

        `mix arcana.install` detects it and writes it into the migration it
        generates, so a generated install already has this filled in.
        """

      other ->
        raise ArgumentError, ":dimensions must be a positive integer, got: #{inspect(other)}"
    end
  end

  @doc """
  The dimension a `format_type` string declares, or `nil` when it carries none.

  Public so the parsing is testable without relocating the pgvector extension
  to force a schema-qualified type name.

      iex> Arcana.Migration.Dimensions.declared_dimension("vector(384)")
      384

      iex> Arcana.Migration.Dimensions.declared_dimension("myschema.vector(1024)")
      1024

      iex> Arcana.Migration.Dimensions.declared_dimension("vector")
      nil
  """
  def declared_dimension(declared) when is_binary(declared) do
    # pgvector has more than one sized type, and format_type schema-qualifies
    # the name when the extension is not on the connection's search_path.
    case Regex.run(
           ~r/\A(?:[\w"]+\.)?(?:vector|halfvec|sparsevec)\((\d+)\)\z/,
           String.trim(declared)
         ) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  def declared_dimension(_), do: nil

  @doc """
  Raises when `table`.embedding already exists with a different dimension.

  `create_if_not_exists` leaves an existing table alone, so a wrong number
  changes nothing and reports success: the divergence only appears when a
  fresh database is built. Comparing against the column that is actually
  there catches it where it was typed.

  Reads the catalog rather than the embedder, so it costs one query and does
  not drag a model load into the migration.
  """
  def verify!(repo, requested, module, table, prefix, remedy) do
    %{rows: rows} =
      repo.query!(
        "SELECT format_type(a.atttypid, a.atttypmod) FROM pg_attribute a " <>
          "JOIN pg_class c ON c.oid = a.attrelid " <>
          "JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE c.relname = $1 AND a.attname = 'embedding' " <>
          "AND a.attnum > 0 AND NOT a.attisdropped " <>
          "AND " <> SchemaScope.visible("c", "n", "$2"),
        [table, prefix]
      )

    # pgvector has more than one sized type, so the match is not vector-only,
    # and format_type schema-qualifies the type when the extension is not on
    # the connection's search_path (`myschema.vector(384)`), so the qualifier
    # is optional rather than absent.
    # Anything without a dimension is left alone rather than guessed at: an
    # unsized `vector` column can't reach production here anyway, because
    # creating the HNSW index on it fails with "column does not have
    # dimensions" later in the same migration.
    with [[declared]] when is_binary(declared) <- rows,
         actual when is_integer(actual) <- declared_dimension(declared),
         true <- actual != requested do
      raise ArgumentError, """
      #{inspect(module)}.up/1 was given dimensions: #{requested}, but
      #{table}.embedding is already vector(#{actual}).

      The column was not changed: create_if_not_exists leaves an existing
      table alone, so the mismatch would have gone unnoticed until a fresh
      database was built with #{requested} and this one kept #{actual}.

      Pass dimensions: #{actual} to match this database, or if #{requested} is
      the number you want: #{remedy}
      """
    end

    :ok
  end
end
