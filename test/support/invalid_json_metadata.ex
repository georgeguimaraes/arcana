defmodule Arcana.InvalidJSONMetadata do
  @moduledoc false

  defstruct [:value]
end

defimpl JSON.Encoder, for: Arcana.InvalidJSONMetadata do
  def encode(_metadata, _encoder), do: [:invalid_iodata]
end
