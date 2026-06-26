defmodule Magus.Workspaces.Backfill.ImplicitWorkspaceShares do
  @moduledoc """
  One-shot backfill: for every prompt, custom_agent, and file with workspace_id
  not null, create a workspace-level :viewer grant in resource_accesses.
  Captures the pre-Path-B implicit "workspace_id set = team-readable" semantics
  as explicit grants. Idempotent via the unique identity on resource_accesses.
  """

  @targets [
    {"prompts", "prompt", ""},
    {"custom_agents", "custom_agent", ""},
    {"files", "file", " AND deleted_at IS NULL"}
  ]

  def run do
    Enum.reduce(@targets, 0, fn {table, resource_type, extra_where}, acc ->
      acc + backfill_table(table, resource_type, extra_where)
    end)
  end

  defp backfill_table(table, resource_type, extra_where) do
    repo = Magus.Repo
    now = DateTime.utc_now()

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        repo,
        """
        SELECT id, workspace_id, user_id
        FROM #{table}
        WHERE workspace_id IS NOT NULL#{extra_where}
        """,
        []
      )

    entries =
      Enum.map(rows, fn [id, ws_id, uid] ->
        %{
          id: new_uuid_bin(),
          resource_type: resource_type,
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
