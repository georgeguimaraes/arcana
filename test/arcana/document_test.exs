defmodule Arcana.DocumentTest do
  use Arcana.DataCase, async: true

  alias Arcana.Document

  describe "changeset/2" do
    test "valid with required fields" do
      changeset = Document.changeset(%Document{}, %{content: "Hello world"})

      assert changeset.valid?
    end

    test "invalid without content" do
      changeset = Document.changeset(%Document{}, %{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).content
    end

    test "sets default status to pending" do
      changeset = Document.changeset(%Document{}, %{content: "test"})

      assert Ecto.Changeset.get_field(changeset, :status) == :pending
    end

    test "accepts optional fields" do
      attrs = %{
        content: "test",
        content_type: "application/pdf",
        source_id: "doc-123",
        file_path: "/path/to/file.pdf",
        metadata: %{"author" => "Jane"}
      }

      changeset = Document.changeset(%Document{}, attrs)

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :source_id) == "doc-123"
    end
  end

  describe "database operations" do
    test "inserts and retrieves document" do
      {:ok, doc} =
        %Document{}
        |> Document.changeset(%{content: "Test content"})
        |> Repo.insert()

      assert doc.id
      assert doc.content == "Test content"
      assert doc.status == :pending

      retrieved = Repo.get!(Document, doc.id)
      assert retrieved.content == "Test content"
    end
  end
end
