defmodule Magus.Workspaces.Backfill.BrainAccess do
  @moduledoc """
  One-shot backfill: migrate brain_accesses rows into resource_accesses
  (resource_type = :brain). Preserves grantee_type, grantee_id, and role,
  mapping BrainAccess's :admin role to resource_access :owner. Idempotent
  via the unique identity on resource_accesses.
  """

  @role_mapping %{"admin" => "owner", "editor" => "editor", "viewer" => "viewer"}

  def run do
    repo = Magus.Repo
    now = DateTime.utc_now()

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        repo,
        """
        SELECT brain_id, grantee_type, grantee_id, role, inserted_at
        FROM brain_accesses
        """,
        []
      )

    entries =
      Enum.map(rows, fn [brain_id, grantee_type, grantee_id, role, inserted_at] ->
        %{
          id: new_uuid_bin(),
          resource_type: "brain",
          resource_id: brain_id,
          grantee_type: grantee_type,
          grantee_id: grantee_id,
          role: Map.fetch!(@role_mapping, role),
          granted_by_id: nil,
          granted_at: inserted_at,
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
