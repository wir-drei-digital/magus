defmodule Magus.Workspaces.Backfill.Conversations do
  @moduledoc """
  One-shot backfill: for every conversation with workspace_visibility == :shared
  AND workspace_id not null, create a corresponding workspace-level :viewer grant
  in resource_accesses. Idempotent via the unique identity on resource_accesses.
  """

  def run do
    repo = Magus.Repo
    now = DateTime.utc_now()

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        repo,
        """
        SELECT id, workspace_id, user_id
        FROM conversations
        WHERE workspace_id IS NOT NULL
          AND workspace_visibility = 'shared'
        """,
        []
      )

    entries =
      Enum.map(rows, fn [id, ws_id, uid] ->
        %{
          id: new_uuid_bin(),
          resource_type: "conversation",
          resource_id: id,
          grantee_type: "workspace",
          grantee_id: ws_id,
          role: "viewer",
          granted_by_id: uid,
          granted_at: now,
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

  defp new_uuid_bin do
    case Ecto.UUID.dump(Ash.UUIDv7.generate()) do
      {:ok, bin} -> bin
      :error -> raise "failed to dump UUID"
    end
  end
end
