defmodule Magus.Repo.Migrations.AddBlockTextSearch do
  use Ecto.Migration

  def up do
    # Add a generated tsvector column based on content->>'text'
    execute """
    ALTER TABLE brain_blocks
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (to_tsvector('english', COALESCE(content->>'text', ''))) STORED
    """

    # Add GIN index for fast full-text search
    execute """
    CREATE INDEX brain_blocks_search_vector_idx ON brain_blocks USING GIN (search_vector)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS brain_blocks_search_vector_idx"
    execute "ALTER TABLE brain_blocks DROP COLUMN IF EXISTS search_vector"
  end
end
