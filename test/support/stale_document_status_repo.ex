defmodule Arcana.StaleDocumentStatusRepo do
  @moduledoc false

  alias Arcana.{Document, TestRepo}

  def get(Document, id) do
    case TestRepo.get(Document, id) do
      nil -> nil
      document -> %{document | status: :processing}
    end
  end

  def transaction(fun), do: TestRepo.transaction(fun)
  def in_transaction?, do: TestRepo.in_transaction?()
  def one(query), do: TestRepo.one(query)
  def all(query), do: TestRepo.all(query)
  def delete(struct), do: TestRepo.delete(struct)
  def rollback(reason), do: TestRepo.rollback(reason)
end
