defmodule Magus.Repo.Migrations.AddMemoriesUserIdIndex do
  @moduledoc """
  Adds index on user_id for memories table to improve authorization query performance.
  """

  use Ecto.Migration

  def change do
    # Index for authorization queries that filter by user_id
    create index(:memories, [:user_id, :is_active])
  end
end
