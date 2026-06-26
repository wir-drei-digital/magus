defmodule Magus.Models.DefaultFlagsBackfill do
  @moduledoc """
  One-time migration of the legacy default-model boolean flags into
  `Magus.Models.RoleAssignment` rows, making roles the single source of
  truth for default chat/image/video models.

  For every model with `default? == true` it upserts a `:chat_default`
  assignment; `default_image? == true` → `:image_default`;
  `default_video? == true` → `:video_t2v`.

  Reads the flags via raw SQL (not the Ash resource) so it keeps working
  from a data migration that runs *before* the schema migration drops the
  columns, and after the resource attributes are gone.

  Idempotent: skips a role that already has a DB assignment, so existing
  admin choices are never overwritten and re-running is a no-op.

  > One-shot data-migration helper invoked from a migration, not general
  > runtime code. Do not call from request/agent paths.
  """

  require Logger

  @flag_roles [
    {"default", "chat_default"},
    {"default_image", "image_default"},
    {"default_video", "video_t2v"}
  ]

  @spec run() :: :ok
  def run do
    Enum.each(@flag_roles, fn {column, role} ->
      case flagged_model_id(column) do
        nil -> :ok
        model_id -> ensure_assignment(role, model_id)
      end
    end)

    :ok
  end

  # Reads the earliest-created model carrying the given flag. The flag was a
  # singleton in practice; ordering keeps the result deterministic if more
  # than one row somehow carries it. The flag columns are named with a
  # trailing `?` (e.g. `default?`), so they must be double-quoted in SQL.
  defp flagged_model_id(column) do
    sql =
      ~s|SELECT id FROM models WHERE "#{column}?" = true ORDER BY inserted_at ASC LIMIT 1|

    case Ecto.Adapters.SQL.query(Magus.Repo, sql, []) do
      {:ok, %{rows: [[id]]}} -> decode_uuid(id)
      _ -> nil
    end
  rescue
    # Column already dropped (schema migration ran first) — nothing to backfill.
    # Only swallow undefined_column; re-raise any other SQL error so a real
    # problem isn't silently skipped.
    e in Postgrex.Error ->
      if e.postgres.code == :undefined_column,
        do: nil,
        else: reraise(e, __STACKTRACE__)
  end

  defp decode_uuid(id) when is_binary(id) do
    case Ecto.UUID.load(id) do
      {:ok, uuid} -> uuid
      :error -> id
    end
  end

  defp ensure_assignment(role, model_id) do
    case Magus.Models.get_role_assignment(role, authorize?: false) do
      {:ok, %Magus.Models.RoleAssignment{}} ->
        # An assignment already exists for this role; leave it untouched.
        :ok

      _ ->
        Magus.Models.assign_role(
          %{role: role, model_id: model_id},
          authorize?: false
        )
        |> case do
          {:ok, _} ->
            Logger.info("DefaultFlagsBackfill: assigned #{role} -> #{model_id}")
            :ok

          {:error, error} ->
            Logger.warning(
              "DefaultFlagsBackfill: failed to assign #{role}: " <>
                inspect(error)
            )

            :ok
        end
    end
  end
end
