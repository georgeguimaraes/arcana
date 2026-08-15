defmodule PagedFixtureParser do
  @moduledoc false
  @behaviour Arcana.FileParser

  # Three pages of roughly 40 bytes each, joined by newlines the way
  # pdftotext-style extraction would hand them over.
  @pages [
    "Alpha alpha alpha the first page text.",
    "Bravo bravo bravo the second page text.",
    "Delta delta delta the third page text."
  ]

  def text, do: Enum.join(@pages, "\n")

  def pages do
    {ranges, _offset} =
      Enum.reduce(@pages, {[], 0}, fn page, {acc, offset} ->
        range = %{number: length(acc) + 1, start: offset, end: offset + byte_size(page)}
        # +1 for the newline joining this page to the next
        {[range | acc], offset + byte_size(page) + 1}
      end)

    Enum.reverse(ranges)
  end

  @impl true
  def parse(_input, _opts), do: {:ok, text(), %{pages: pages()}}

  @impl true
  def supports_binary?, do: true
end

defmodule BinaryDocxParser do
  @moduledoc false
  @behaviour Arcana.FileParser

  @impl true
  def parse(input, _opts), do: {:ok, "extracted<#{input}>"}

  @impl true
  def supports_binary?, do: true
end

defmodule PathBoundParser do
  @moduledoc false
  @behaviour Arcana.FileParser

  @impl true
  def parse(_input, _opts), do: {:ok, "never reached"}
end

defmodule Arcana.IngestBinaryTest do
  use Arcana.DataCase, async: true

  alias Arcana.{Chunk, Parser}

  defp chunks_of(document) do
    Repo.all(from(c in Chunk, where: c.document_id == ^document.id, order_by: c.chunk_index))
  end

  describe "ingest_binary/2" do
    test "ingests bytes, recording the filename as provenance" do
      content = "Some notes typed straight into memory, never written to disk."

      assert {:ok, document} =
               Arcana.ingest_binary(content, filename: "notes.txt", repo: Repo)

      assert document.content == content
      assert document.status == :completed
      assert document.file_path == "notes.txt"
      assert document.content_type == "text/plain"
      assert document.chunk_count == length(chunks_of(document))
    end

    test "routes on the filename's extension and its parser's content type" do
      put_arcana_env(:file_parsers, %{
        ".docx" => {BinaryDocxParser, content_type: "application/vnd.docx"}
      })

      assert {:ok, document} =
               Arcana.ingest_binary("raw-bytes", filename: "report.docx", repo: Repo)

      assert document.content == "extracted<raw-bytes>"
      assert document.content_type == "application/vnd.docx"
    end

    test "a path-only parser reports binary_unsupported instead of crashing" do
      put_arcana_env(:file_parsers, %{".docx" => PathBoundParser})

      assert {:error, {:binary_unsupported, PathBoundParser}} =
               Arcana.ingest_binary("raw-bytes", filename: "report.docx", repo: Repo)
    end

    test "PDF bytes report binary_unsupported: poppler shells out to a real file" do
      assert {:error, {:binary_unsupported, Arcana.FileParser.PDF.Poppler}} =
               Arcana.ingest_binary("%PDF-1.4 whatever", filename: "manual.pdf", repo: Repo)
    end

    test "unknown extensions are unsupported" do
      assert {:error, :unsupported_format} =
               Arcana.ingest_binary("raw", filename: "thing.rtf", repo: Repo)
    end

    test "requires a filename to route on" do
      assert_raise ArgumentError, ~r/requires a :filename/, fn ->
        Arcana.ingest_binary("raw", repo: Repo)
      end
    end

    test "no document is created when parsing fails" do
      before = Repo.aggregate(Arcana.Document, :count)

      assert {:error, :unsupported_format} =
               Arcana.ingest_binary("raw", filename: "thing.rtf", repo: Repo)

      assert Repo.aggregate(Arcana.Document, :count) == before
    end
  end

  describe "parity with ingest_file/2" do
    test "collection, source_id and metadata land the same way" do
      content = "Identical content ingested two different ways for comparison."

      path =
        Path.join(System.tmp_dir!(), "arcana_parity_#{System.unique_integer([:positive])}.txt")

      File.write!(path, content)
      on_exit(fn -> File.rm(path) end)

      opts = [
        repo: Repo,
        collection: "parity-check",
        source_id: "doc-42",
        metadata: %{"origin" => "test"}
      ]

      assert {:ok, from_file} = Arcana.ingest_file(path, opts)
      assert {:ok, from_binary} = Arcana.ingest_binary(content, [filename: "parity.txt"] ++ opts)

      assert from_binary.content == from_file.content
      assert from_binary.source_id == from_file.source_id
      assert from_binary.collection_id == from_file.collection_id
      assert from_binary.content_type == from_file.content_type
      assert from_binary.metadata == from_file.metadata
      assert from_binary.chunk_count == from_file.chunk_count

      # only provenance differs: one points at a path, one at the name
      assert from_file.file_path == path
      assert from_binary.file_path == "parity.txt"
    end

    test "strict_collections rejects an unknown collection for binaries too" do
      put_arcana_env(:strict_collections, true)

      assert {:error, {:unknown_collection, "nope"}} =
               Arcana.ingest_binary("text", filename: "a.txt", repo: Repo, collection: "nope")
    end
  end

  describe "stored chunk metadata" do
    test "offsets survive the database and slice back to each chunk's text" do
      text =
        Enum.map_join(1..40, "\n\n", fn i ->
          "Paragraph #{i} with enough words in it to make the chunker split things up."
        end)

      assert {:ok, document} =
               Arcana.ingest_binary(text,
                 filename: "long.txt",
                 repo: Repo,
                 chunk_size: 60,
                 chunk_overlap: 10
               )

      chunks = chunks_of(document)
      assert length(chunks) > 1

      for chunk <- chunks do
        start_byte = chunk.metadata["start_byte"]
        end_byte = chunk.metadata["end_byte"]

        assert is_integer(start_byte), "offsets missing from stored metadata"
        assert is_integer(end_byte)
        assert binary_part(text, start_byte, end_byte - start_byte) == chunk.text
      end
    end

    test "plain-text ingest stores offsets too" do
      text = Enum.map_join(1..30, "\n\n", fn i -> "Line #{i} of some reasonably wordy text." end)

      assert {:ok, document} = Arcana.ingest(text, repo: Repo, chunk_size: 50)

      for chunk <- chunks_of(document) do
        assert binary_part(
                 text,
                 chunk.metadata["start_byte"],
                 chunk.metadata["end_byte"] - chunk.metadata["start_byte"]
               ) == chunk.text
      end
    end

    test "a chunker's extra keys reach storage, as the behaviour promises" do
      put_arcana_env(:chunker, fn _text, _opts ->
        [%{text: "only chunk", chunk_index: 0, token_count: 2, page: 7, section: "intro"}]
      end)

      assert {:ok, document} = Arcana.ingest("whatever", repo: Repo)

      assert [chunk] = chunks_of(document)
      assert chunk.metadata["page"] == 7
      assert chunk.metadata["section"] == "intro"
    end
  end

  describe "page derivation" do
    setup do
      put_arcana_env(:file_parsers, %{".paged" => PagedFixtureParser})
      :ok
    end

    test "a chunk spanning page breaks reports different start and end pages" do
      # One chunk big enough to swallow all three pages
      assert {:ok, document} =
               Arcana.ingest_binary("ignored",
                 filename: "doc.paged",
                 repo: Repo,
                 chunk_size: 10_000
               )

      assert [chunk] = chunks_of(document)
      assert chunk.metadata["page_start"] == 1
      assert chunk.metadata["page_end"] == 3
    end

    test "each chunk's pages match the page its byte range falls in" do
      assert {:ok, document} =
               Arcana.ingest_binary("ignored",
                 filename: "doc.paged",
                 repo: Repo,
                 chunk_size: 12,
                 chunk_overlap: 0,
                 size_unit: :characters
               )

      chunks = chunks_of(document)
      assert length(chunks) > 1

      pages = PagedFixtureParser.pages()

      for chunk <- chunks do
        page_start = chunk.metadata["page_start"]
        page_end = chunk.metadata["page_end"]

        assert page_start in 1..3
        assert page_end in 1..3
        assert page_start <= page_end

        # independently recompute the page holding the chunk's first byte
        expected =
          Enum.find(pages, fn page ->
            chunk.metadata["start_byte"] >= page.start and chunk.metadata["start_byte"] < page.end
          end)

        if expected, do: assert(page_start == expected.number)
      end

      # the document really does span more than one page
      assert chunks |> Enum.map(& &1.metadata["page_start"]) |> Enum.uniq() |> length() > 1
    end

    test "a custom chunker's atom-keyed offsets still get pages" do
      [_page_one, page_two, _page_three] = PagedFixtureParser.pages()

      put_arcana_env(:chunker, fn text, _opts ->
        [
          %{
            text: binary_part(text, page_two.start, page_two.end - page_two.start),
            chunk_index: 0,
            token_count: 5,
            metadata: %{start_byte: page_two.start, end_byte: page_two.end}
          }
        ]
      end)

      assert {:ok, document} =
               Arcana.ingest_binary("ignored", filename: "doc.paged", repo: Repo)

      assert [chunk] = chunks_of(document)
      assert chunk.metadata["start_byte"] == page_two.start
      assert chunk.metadata["page_start"] == 2
      assert chunk.metadata["page_end"] == 2
    end

    test "offsets handed back as top-level extras still get pages" do
      [_page_one, _page_two, page_three] = PagedFixtureParser.pages()

      put_arcana_env(:chunker, fn text, _opts ->
        [
          %{
            text: binary_part(text, page_three.start, page_three.end - page_three.start),
            chunk_index: 0,
            token_count: 5,
            start_byte: page_three.start,
            end_byte: page_three.end
          }
        ]
      end)

      assert {:ok, document} =
               Arcana.ingest_binary("ignored", filename: "doc.paged", repo: Repo)

      assert [chunk] = chunks_of(document)
      assert chunk.metadata["page_start"] == 3
      assert chunk.metadata["page_end"] == 3
    end

    test "parsers without page metadata leave chunks page-free" do
      assert {:ok, document} =
               Arcana.ingest_binary("plain text with no pages at all",
                 filename: "notes.txt",
                 repo: Repo
               )

      for chunk <- chunks_of(document) do
        refute Map.has_key?(chunk.metadata, "page_start")
        assert is_integer(chunk.metadata["start_byte"])
      end
    end

    test "search results expose the page a hit came from" do
      assert {:ok, _document} =
               Arcana.ingest_binary("ignored",
                 filename: "doc.paged",
                 repo: Repo,
                 chunk_size: 12,
                 chunk_overlap: 0,
                 size_unit: :characters
               )

      assert {:ok, results} = Arcana.search("Delta delta delta", repo: Repo, limit: 10)

      assert [%Arcana.SearchResult{} | _] = results
      assert Enum.all?(results, &is_integer(&1.metadata["page_start"]))

      # "delta" only appears on the third page, so any hit carrying it
      # must reach page 3 — the whole point of deriving pages at ingest.
      # A chunk straddling the page 2/3 break legitimately starts on 2.
      hits = Enum.filter(results, &String.contains?(String.downcase(&1.text), "delta"))

      assert hits != []
      assert Enum.all?(hits, &(&1.metadata["page_end"] == 3))
      assert Enum.all?(hits, &(&1.metadata["page_start"] in 2..3))
    end
  end

  describe "content_type_for/1 drives ingestion" do
    test "a registered parser's declared content type is what gets stored" do
      put_arcana_env(:file_parsers, %{
        ".docx" => {BinaryDocxParser, content_type: "application/vnd.docx"}
      })

      assert Parser.content_type_for("a.docx") == "application/vnd.docx"

      assert {:ok, document} = Arcana.ingest_binary("x", filename: "a.docx", repo: Repo)
      assert document.content_type == "application/vnd.docx"
    end
  end
end
