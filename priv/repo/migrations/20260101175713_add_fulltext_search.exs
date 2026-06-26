defmodule Magus.Repo.Migrations.AddFulltextSearch do
  @moduledoc """
  Adds PostgreSQL full-text search capabilities with pg_trgm extension
  for typo tolerance. Creates generated tsvector columns and GIN indexes
  for efficient searching across messages, conversations, blocks, stacks,
  memory resources, and memory chunks.
  """
  use Ecto.Migration

  def up do
    # Enable pg_trgm extension for fuzzy matching
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"

    # =====================
    # messages (Magus.Chat.Message)
    # =====================
    execute """
    ALTER TABLE messages
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (to_tsvector('simple', coalesce(text, ''))) STORED
    """

    execute "CREATE INDEX messages_search_idx ON messages USING GIN (search_vector)"
    execute "CREATE INDEX messages_text_trgm_idx ON messages USING GIN (text gin_trgm_ops)"

    # =====================
    # conversations (Magus.Chat.Conversation)
    # =====================
    execute """
    ALTER TABLE conversations
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (to_tsvector('simple', coalesce(title, ''))) STORED
    """

    execute "CREATE INDEX conversations_search_idx ON conversations USING GIN (search_vector)"

    execute "CREATE INDEX conversations_title_trgm_idx ON conversations USING GIN (title gin_trgm_ops)"

    # =====================
    # blocks (Magus.Brain.Block)
    # =====================
    execute """
    ALTER TABLE blocks
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      to_tsvector('simple', coalesce(name, '') || ' ' || coalesce(content, ''))
    ) STORED
    """

    execute "CREATE INDEX blocks_search_idx ON blocks USING GIN (search_vector)"
    execute "CREATE INDEX blocks_name_trgm_idx ON blocks USING GIN (name gin_trgm_ops)"
    execute "CREATE INDEX blocks_content_trgm_idx ON blocks USING GIN (content gin_trgm_ops)"

    # =====================
    # stacks (Magus.Brain.Stack)
    # =====================
    execute """
    ALTER TABLE stacks
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      to_tsvector('simple', coalesce(name, '') || ' ' || coalesce(description, ''))
    ) STORED
    """

    execute "CREATE INDEX stacks_search_idx ON stacks USING GIN (search_vector)"
    execute "CREATE INDEX stacks_name_trgm_idx ON stacks USING GIN (name gin_trgm_ops)"

    # =====================
    # memory_resources (Magus.Memory.Resource)
    # =====================
    execute """
    ALTER TABLE memory_resources
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (to_tsvector('simple', coalesce(name, ''))) STORED
    """

    execute "CREATE INDEX memory_resources_search_idx ON memory_resources USING GIN (search_vector)"

    execute "CREATE INDEX memory_resources_name_trgm_idx ON memory_resources USING GIN (name gin_trgm_ops)"
  end

  def down do
    # memory_chunks
    execute "DROP INDEX IF EXISTS memory_chunks_content_trgm_idx"
    execute "DROP INDEX IF EXISTS memory_chunks_search_idx"
    execute "ALTER TABLE memory_chunks DROP COLUMN IF EXISTS search_tsv"

    # memory_resources
    execute "DROP INDEX IF EXISTS memory_resources_name_trgm_idx"
    execute "DROP INDEX IF EXISTS memory_resources_search_idx"
    execute "ALTER TABLE memory_resources DROP COLUMN IF EXISTS search_vector"

    # stacks
    execute "DROP INDEX IF EXISTS stacks_name_trgm_idx"
    execute "DROP INDEX IF EXISTS stacks_search_idx"
    execute "ALTER TABLE stacks DROP COLUMN IF EXISTS search_vector"

    # blocks
    execute "DROP INDEX IF EXISTS blocks_content_trgm_idx"
    execute "DROP INDEX IF EXISTS blocks_name_trgm_idx"
    execute "DROP INDEX IF EXISTS blocks_search_idx"
    execute "ALTER TABLE blocks DROP COLUMN IF EXISTS search_vector"

    # conversations
    execute "DROP INDEX IF EXISTS conversations_title_trgm_idx"
    execute "DROP INDEX IF EXISTS conversations_search_idx"
    execute "ALTER TABLE conversations DROP COLUMN IF EXISTS search_vector"

    # messages
    execute "DROP INDEX IF EXISTS messages_text_trgm_idx"
    execute "DROP INDEX IF EXISTS messages_search_idx"
    execute "ALTER TABLE messages DROP COLUMN IF EXISTS search_vector"
  end
end
