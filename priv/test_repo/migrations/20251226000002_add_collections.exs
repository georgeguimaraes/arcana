defmodule Arcana.TestRepo.Migrations.AddCollections do
  use Ecto.Migration

  def change do
    create table(:arcana_collections, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:description, :text)

      timestamps()
    end

    create(unique_index(:arcana_collections, [:name]))

    alter table(:arcana_documents) do
      add(:collection_id, references(:arcana_collections, type: :binary_id, on_delete: :restrict))
    end

    create(index(:arcana_documents, [:collection_id]))
  end
end
