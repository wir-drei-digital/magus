defmodule Magus.Workspaces.MemberUsage do
  @moduledoc """
  Per-member usage aggregation for the workspace admin usage view: credits
  consumed today (billable), storage used, and last activity.

  These are raw Ecto rollups across `MessageUsage` / `Files.File` / `Message`;
  there is no single Ash resource for this cross-resource aggregate. Access is
  admin-gated: the workspace `:read` policy already requires membership, and
  `ensure_admin/2` narrows that to active admins.
  """
  import Ecto.Query

  @doc """
  Returns `{:ok, [%{"user_id" => ..., "credits" => ..., "storage_bytes" => ...,
  "last_active_at" => ...}]}` for the workspace's active members, most-recently
  active first. `{:error, _}` if the actor is not an active admin.
  """
  @spec for_workspace(Ecto.UUID.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def for_workspace(workspace_id, opts) do
    actor = Keyword.fetch!(opts, :actor)

    with {:ok, workspace} <-
           Magus.Workspaces.get_workspace(workspace_id, actor: actor, load: [members: [:user]]),
         :ok <- ensure_admin(workspace, actor) do
      active_members = Enum.filter(workspace.members, & &1.is_active)
      user_ids = active_members |> Enum.map(& &1.user_id) |> Enum.reject(&is_nil/1)

      credits = credits_today_by_user(user_ids)
      storage = storage_by_user(workspace_id, user_ids)
      last_active = last_active_by_user(workspace_id, user_ids)

      rows =
        active_members
        |> Enum.filter(& &1.user_id)
        |> Enum.map(fn member ->
          %{
            "user_id" => member.user_id,
            "credits" => Map.get(credits, member.user_id, 0),
            "storage_bytes" => Map.get(storage, member.user_id, 0),
            "last_active_at" => Map.get(last_active, member.user_id)
          }
        end)
        |> Enum.sort_by(
          fn row -> row["last_active_at"] || ~U[1970-01-01 00:00:00Z] end,
          {:desc, DateTime}
        )

      {:ok, rows}
    end
  end

  defp ensure_admin(workspace, actor) do
    admin? =
      Enum.any?(
        workspace.members,
        &(&1.user_id == actor.id and &1.is_active and &1.role == :admin)
      )

    if admin?, do: :ok, else: {:error, Ash.Error.Forbidden.exception([])}
  end

  # UTC day window (per-user timezones would need one query per timezone; the
  # minor drift is acceptable for an owner-facing aggregate).
  defp credits_today_by_user([]), do: %{}

  defp credits_today_by_user(user_ids) do
    start_utc = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
    end_utc = DateTime.add(start_utc, 1, :day)

    from(u in Magus.Usage.MessageUsage,
      where:
        u.user_id in ^user_ids and u.billable == true and
          u.inserted_at >= ^start_utc and u.inserted_at < ^end_utc,
      group_by: u.user_id,
      select: {u.user_id, sum(u.credits_consumed)}
    )
    |> Magus.Repo.all()
    |> Map.new(fn {uid, credits} -> {uid, to_int(credits)} end)
  end

  # deleted_at IS NULL guard is manual: Ash base_filter does not apply to raw Ecto.
  defp storage_by_user(_workspace_id, []), do: %{}

  defp storage_by_user(workspace_id, user_ids) do
    from(f in Magus.Files.File,
      where: f.workspace_id == ^workspace_id and f.user_id in ^user_ids and is_nil(f.deleted_at),
      group_by: f.user_id,
      select: {f.user_id, sum(f.file_size)}
    )
    |> Magus.Repo.all()
    |> Map.new(fn {uid, sum} -> {uid, to_int(sum)} end)
  end

  defp last_active_by_user(_workspace_id, []), do: %{}

  defp last_active_by_user(workspace_id, user_ids) do
    from(m in Magus.Chat.Message,
      join: c in Magus.Chat.Conversation,
      on: c.id == m.conversation_id,
      where: c.workspace_id == ^workspace_id and m.created_by_id in ^user_ids and m.role == :user,
      group_by: m.created_by_id,
      select: {m.created_by_id, max(m.inserted_at)}
    )
    |> Magus.Repo.all()
    |> Map.new()
  end

  # SUM(integer) crosses Ecto as integer (sometimes Decimal); coerce defensively.
  defp to_int(nil), do: 0
  defp to_int(%Decimal{} = decimal), do: Decimal.to_integer(decimal)
  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: trunc(value)
end
