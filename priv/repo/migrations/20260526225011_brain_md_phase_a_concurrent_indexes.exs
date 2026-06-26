defmodule Magus.Repo.Migrations.BrainMdPhaseAConcurrentIndexes do
  @moduledoc """
  Concurrent index build for the Phase A tables. Separated from the main
  Phase A migration because `CREATE INDEX CONCURRENTLY` cannot run inside
  a transaction; this file disables the DDL transaction and migration
  lock so production deploys don't block writers on the new tables.

  Three indexes:

    * GIN on `brain_pages.search_vector` for full-text search.
    * HNSW (cosine) on `brain_page_chunks.embedding` for semantic search.
    * HNSW (cosine) on `brain_source_chunks.embedding` for semantic search
      over ingested source content.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS brain_pages_search_vector_idx
    ON brain_pages USING GIN (search_vector)
    """

    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS brain_page_chunks_embedding_idx
    ON brain_page_chunks
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    """

    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS brain_source_chunks_embedding_idx
    ON brain_source_chunks
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS brain_source_chunks_embedding_idx"
    execute "DROP INDEX CONCURRENTLY IF EXISTS brain_page_chunks_embedding_idx"
    execute "DROP INDEX CONCURRENTLY IF EXISTS brain_pages_search_vector_idx"
  end
end
