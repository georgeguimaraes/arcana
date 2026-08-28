defmodule Arcana.DocumentMetadata do
  @moduledoc """
  Sparse document attribution returned by `Arcana.get_document_metadata/2`.

  This shape deliberately leaves out document content, ingestion state, and
  associations. Use `to_map/1` when passing it to an encoder or another API.
  """

  defstruct [:id, :source_id, metadata: %{}]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          source_id: String.t() | nil,
          metadata: map()
        }

  @doc """
  Returns the documented plain-map representation of the metadata projection.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = document) do
    %{
      id: document.id,
      source_id: document.source_id,
      metadata: document.metadata
    }
  end
end
