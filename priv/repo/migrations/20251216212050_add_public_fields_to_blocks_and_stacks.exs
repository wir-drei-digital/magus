defmodule Magus.Repo.Migrations.AddPublicFieldsToBlocksAndStacks do
  @moduledoc """
  Adds public library fields to blocks and stacks tables.
  """
  use Ecto.Migration

  def change do
    alter table(:blocks) do
      add :is_public, :boolean, default: false, null: false
      add :published_at, :utc_datetime_usec
      add :is_highlighted, :boolean, default: false, null: false
    end

    alter table(:stacks) do
      add :is_public, :boolean, default: false, null: false
      add :published_at, :utc_datetime_usec
      add :is_highlighted, :boolean, default: false, null: false
    end

    # Index for querying public items efficiently
    create index(:blocks, [:is_public])
    create index(:blocks, [:is_highlighted])
    create index(:stacks, [:is_public])
    create index(:stacks, [:is_highlighted])
  end
end
