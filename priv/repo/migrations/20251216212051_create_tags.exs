defmodule Magus.Repo.Migrations.CreateTags do
  @moduledoc """
  Creates tags table and join tables for blocks and stacks.
  """
  use Ecto.Migration

  def change do
    # Tags table
    create table(:tags, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :citext, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:tags, [:name])

    # Block tags join table
    create table(:block_tags, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :block_id,
          references(:blocks,
            column: :id,
            name: "block_tags_block_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :tag_id,
          references(:tags,
            column: :id,
            name: "block_tags_tag_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:block_tags, [:block_id, :tag_id])
    create index(:block_tags, [:block_id])
    create index(:block_tags, [:tag_id])

    # Stack tags join table
    create table(:stack_tags, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :stack_id,
          references(:stacks,
            column: :id,
            name: "stack_tags_stack_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :tag_id,
          references(:tags,
            column: :id,
            name: "stack_tags_tag_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:stack_tags, [:stack_id, :tag_id])
    create index(:stack_tags, [:stack_id])
    create index(:stack_tags, [:tag_id])
  end
end
