defmodule Magus.Repo.Migrations.CreateMemoryTables do
  @moduledoc """
  Creates the memories and memory_versions tables for the Memory domain.

  The Memory domain provides persistent storage for AI agent memories within
  conversations. Each memory is topic-based (identified by name) and can
  contain arbitrary JSON content with a searchable summary.
  """

  use Ecto.Migration

  def change do
    create table(:memories, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :string, null: false
      add :summary, :text
      add :summary_embedding, :vector, size: 1536
      add :content, :map, default: %{}
      add :lock_version, :integer, default: 0, null: false
      add :is_active, :boolean, default: true
      add :last_accessed_at, :utc_datetime_usec
      add :last_extraction_at, :utc_datetime_usec

      add :conversation_id,
          references(:conversations, type: :uuid, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Unique constraint on name within a conversation (only for active memories)
    create unique_index(:memories, [:conversation_id, :name], where: "is_active = true")

    # Index for fetching memories by conversation sorted by last access
    create index(:memories, [:conversation_id, :last_accessed_at])

    # Index for vector similarity search (using HNSW for pgvector)
    # HNSW is a good default choice for most use cases
    execute(
      """
      CREATE INDEX memories_summary_embedding_index ON memories
      USING hnsw (summary_embedding vector_l2_ops)
      WHERE summary_embedding IS NOT NULL
      """,
      "DROP INDEX IF EXISTS memories_summary_embedding_index"
    )

    create table(:memory_versions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :content, :map, null: false
      add :summary, :text
      add :version, :integer, null: false
      # Stored as string, cast to atom by Ash
      add :changed_by, :string, null: true
      add :change_description, :text

      add :memory_id, references(:memories, type: :uuid, on_delete: :delete_all), null: false

      add :inserted_at, :utc_datetime_usec, null: false
    end

    # Index for fetching versions of a specific memory
    create index(:memory_versions, [:memory_id, :version])
  end
end
