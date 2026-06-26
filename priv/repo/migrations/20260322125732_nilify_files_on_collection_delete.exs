defmodule Magus.Repo.Migrations.NilifyFilesOnCollectionDelete do
  @moduledoc """
  Changes the files.knowledge_collection_id FK to SET NULL on delete.

  When a knowledge collection is destroyed, the FK is nilified so the
  async CleanupFiles worker can delete the files without FK violations.
  """

  use Ecto.Migration

  def up do
    drop constraint(:files, "files_knowledge_collection_id_fkey")

    alter table(:files) do
      modify :knowledge_collection_id,
             references(:knowledge_collections,
               column: :id,
               name: "files_knowledge_collection_id_fkey",
               type: :uuid,
               prefix: "public",
               on_delete: :nilify_all
             )
    end

    drop constraint(:knowledge_access, "knowledge_access_knowledge_collection_id_fkey")

    alter table(:knowledge_access) do
      modify :knowledge_collection_id,
             references(:knowledge_collections,
               column: :id,
               name: "knowledge_access_knowledge_collection_id_fkey",
               type: :uuid,
               prefix: "public",
               on_delete: :delete_all
             )
    end
  end

  def down do
    drop constraint(:files, "files_knowledge_collection_id_fkey")

    alter table(:files) do
      modify :knowledge_collection_id,
             references(:knowledge_collections,
               column: :id,
               name: "files_knowledge_collection_id_fkey",
               type: :uuid,
               prefix: "public"
             )
    end

    drop constraint(:knowledge_access, "knowledge_access_knowledge_collection_id_fkey")

    alter table(:knowledge_access) do
      modify :knowledge_collection_id,
             references(:knowledge_collections,
               column: :id,
               name: "knowledge_access_knowledge_collection_id_fkey",
               type: :uuid,
               prefix: "public"
             )
    end
  end
end
