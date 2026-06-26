defmodule Magus.Repo.Migrations.BackfillMemoryWorkspaceId do
  @moduledoc """
  Backfills memories.workspace_id from the parent (conversation/custom_agent)
  for :local and :agent scoped memories. :user-scoped memories are left NULL
  (treated as personal-context per spec 2026-04-25).
  """
  use Ecto.Migration

  @batch 10_000

  def up do
    backfill_local()
    backfill_agent()
  end

  def down, do: :ok

  defp backfill_local do
    repeat_until_zero(fn ->
      %Postgrex.Result{num_rows: count} =
        repo().query!(
          """
          WITH targets AS (
            SELECT m.id, c.workspace_id AS parent_ws
            FROM memories m
            JOIN conversations c ON c.id = m.conversation_id
            WHERE m.scope = 'local'
              AND m.workspace_id IS NULL
              AND c.workspace_id IS NOT NULL
            LIMIT $1
            FOR UPDATE OF m SKIP LOCKED
          )
          UPDATE memories m
          SET workspace_id = t.parent_ws
          FROM targets t
          WHERE m.id = t.id
          """,
          [@batch]
        )

      count
    end)
  end

  defp backfill_agent do
    repeat_until_zero(fn ->
      %Postgrex.Result{num_rows: count} =
        repo().query!(
          """
          WITH targets AS (
            SELECT m.id, ca.workspace_id AS parent_ws
            FROM memories m
            JOIN custom_agents ca ON ca.id = m.custom_agent_id
            WHERE m.scope = 'agent'
              AND m.workspace_id IS NULL
              AND ca.workspace_id IS NOT NULL
            LIMIT $1
            FOR UPDATE OF m SKIP LOCKED
          )
          UPDATE memories m
          SET workspace_id = t.parent_ws
          FROM targets t
          WHERE m.id = t.id
          """,
          [@batch]
        )

      count
    end)
  end

  defp repeat_until_zero(fun) do
    case fun.() do
      0 -> :ok
      _n -> repeat_until_zero(fun)
    end
  end
end
