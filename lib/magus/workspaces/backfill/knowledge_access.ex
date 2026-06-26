defmodule Magus.Workspaces.Backfill.KnowledgeAccess do
  @moduledoc """
  One-shot backfill: migrate knowledge_access rows into resource_accesses.

  Maps the polymorphic (knowledge_collection_id, file_id) pair onto
  (resource_type, resource_id):

    * knowledge_collection_id present -> resource_type = :knowledge_collection
    * file_id present -> resource_type = :file

  Maps can_write onto role:

    * can_write = true -> :editor
    * can_write = false -> :viewer

  Preserves grantee_type, grantee_id, granted_by_id, and granted_at.
  Idempotent via the unique identity on resource_accesses.
  """

  def run do
    repo = Magus.Repo
    now = DateTime.utc_now()

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        repo,
        """
        SELECT knowledge_collection_id, file_id, grantee_type, grantee_id,
               can_write, granted_by_id, granted_at
        FROM knowledge_access
        """,
        []
      )

    entries =
      Enum.map(rows, fn [
                          collection_id,
                          file_id,
                          grantee_type,
                          grantee_id,
                          can_write,
                          granted_by_id,
                          granted_at
                        ] ->
        {resource_type, resource_id} = resource_for(collection_id, file_id)

        %{
          id: new_uuid_bin(),
          resource_type: resource_type,
          resource_id: resource_id,
          grantee_type: grantee_type,
          grantee_id: grantee_id,
          role: role_for(can_write),
          granted_by_id: granted_by_id,
          granted_at: granted_at,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} =
      repo.insert_all("resource_accesses", entries,
        on_conflict: :nothing,
        conflict_target: [:resource_type, :resource_id, :grantee_type, :grantee_id]
      )

    count
  end

  defp resource_for(collection_id, _file_id) when not is_nil(collection_id),
    do: {"knowledge_collection", collection_id}

  defp resource_for(_collection_id, file_id) when not is_nil(file_id),
    do: {"file", file_id}

  defp role_for(true), do: "editor"
  defp role_for(false), do: "viewer"

  defp new_uuid_bin do
    case Ecto.UUID.dump(Ash.UUIDv7.generate()) do
      {:ok, bin} -> bin
      :error -> raise "failed to dump UUID"
    end
  end
end
