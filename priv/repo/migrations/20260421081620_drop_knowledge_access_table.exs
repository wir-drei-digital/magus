defmodule Magus.Repo.Migrations.DropKnowledgeAccessTable do
  use Ecto.Migration

  def up do
    drop_if_exists table(:knowledge_access)
  end

  def down, do: :ok
end
