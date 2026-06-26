defmodule Magus.Repo.Migrations.CreateFavorites do
  @moduledoc """
  Creates favorites tables for blocks and stacks.
  """
  use Ecto.Migration

  def change do
    # Block favorites table
    create table(:block_favorites, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :user_id,
          references(:users,
            column: :id,
            name: "block_favorites_user_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :block_id,
          references(:blocks,
            column: :id,
            name: "block_favorites_block_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:block_favorites, [:user_id, :block_id])
    create index(:block_favorites, [:user_id])
    create index(:block_favorites, [:block_id])

    # Stack favorites table
    create table(:stack_favorites, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :user_id,
          references(:users,
            column: :id,
            name: "stack_favorites_user_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :stack_id,
          references(:stacks,
            column: :id,
            name: "stack_favorites_stack_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:stack_favorites, [:user_id, :stack_id])
    create index(:stack_favorites, [:user_id])
    create index(:stack_favorites, [:stack_id])
  end
end
