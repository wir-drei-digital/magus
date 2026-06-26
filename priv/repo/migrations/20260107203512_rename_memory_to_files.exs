defmodule Magus.Repo.Migrations.RenameMemoryToFiles do
  @moduledoc """
  Renames the Memory domain tables to Files domain tables.

  - memory_resources -> files
  - memory_chunks -> file_chunks
  """
  use Ecto.Migration

  def up do
    # Rename tables
    rename table(:memory_resources), to: table(:files)
    rename table(:memory_chunks), to: table(:file_chunks)

    # Rename resource_id column to file_id
    execute "ALTER TABLE file_chunks RENAME COLUMN resource_id TO file_id"

    # Drop old foreign key and add new one with correct table reference and column name
    execute "ALTER TABLE file_chunks DROP CONSTRAINT memory_chunks_resource_id_fkey"

    execute "ALTER TABLE file_chunks ADD CONSTRAINT file_chunks_file_id_fkey FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE"

    # Rename indexes
    execute "ALTER INDEX memory_resources_pkey RENAME TO files_pkey"
    execute "ALTER INDEX memory_chunks_pkey RENAME TO file_chunks_pkey"

    # Rename any other indexes that exist
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'memory_resources_user_id_index') THEN
        ALTER INDEX memory_resources_user_id_index RENAME TO files_user_id_index;
      END IF;
      IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'memory_resources_conversation_id_index') THEN
        ALTER INDEX memory_resources_conversation_id_index RENAME TO files_conversation_id_index;
      END IF;
      IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'memory_resources_folder_id_index') THEN
        ALTER INDEX memory_resources_folder_id_index RENAME TO files_folder_id_index;
      END IF;
      IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'memory_chunks_resource_id_index') THEN
        ALTER INDEX memory_chunks_resource_id_index RENAME TO file_chunks_file_id_index;
      END IF;
      IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'memory_chunks_embedding_index') THEN
        ALTER INDEX memory_chunks_embedding_index RENAME TO file_chunks_embedding_index;
      END IF;
      IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'memory_resources_search_vector_idx') THEN
        ALTER INDEX memory_resources_search_vector_idx RENAME TO files_search_vector_idx;
      END IF;
      IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'memory_resources_name_trgm_idx') THEN
        ALTER INDEX memory_resources_name_trgm_idx RENAME TO files_name_trgm_idx;
      END IF;
    END $$;
    """
  end

  def down do
    # Rename tables back
    rename table(:files), to: table(:memory_resources)
    rename table(:file_chunks), to: table(:memory_chunks)

    # Rename file_id column back to resource_id
    execute "ALTER TABLE memory_chunks RENAME COLUMN file_id TO resource_id"

    # Drop new foreign key and add old one back
    execute "ALTER TABLE memory_chunks DROP CONSTRAINT file_chunks_file_id_fkey"

    execute "ALTER TABLE memory_chunks ADD CONSTRAINT memory_chunks_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES memory_resources(id) ON DELETE CASCADE"

    # Rename indexes back
    execute "ALTER INDEX files_pkey RENAME TO memory_resources_pkey"
    execute "ALTER INDEX file_chunks_pkey RENAME TO memory_chunks_pkey"

    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'files_user_id_index') THEN
        ALTER INDEX files_user_id_index RENAME TO memory_resources_user_id_index;
      END IF;
      IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'files_conversation_id_index') THEN
        ALTER INDEX files_conversation_id_index RENAME TO memory_resources_conversation_id_index;
      END IF;
      IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'files_folder_id_index') THEN
        ALTER INDEX files_folder_id_index RENAME TO memory_resources_folder_id_index;
      END IF;
      IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'file_chunks_file_id_index') THEN
        ALTER INDEX file_chunks_file_id_index RENAME TO memory_chunks_resource_id_index;
      END IF;
      IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'file_chunks_embedding_index') THEN
        ALTER INDEX file_chunks_embedding_index RENAME TO memory_chunks_embedding_index;
      END IF;
      IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'files_search_vector_idx') THEN
        ALTER INDEX files_search_vector_idx RENAME TO memory_resources_search_vector_idx;
      END IF;
      IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'files_name_trgm_idx') THEN
        ALTER INDEX files_name_trgm_idx RENAME TO memory_resources_name_trgm_idx;
      END IF;
    END $$;
    """
  end
end
