defmodule Magus.Skills.Migrations.BackfillApprovals do
  @moduledoc """
  One-shot backfill: copy legacy `conversations.approved_skill_ids` arrays into
  `conversation_skill_approvals` rows, binding each to the skill's current
  bundle_sha and attributing the conversation owner. Idempotent (ON CONFLICT
  DO NOTHING via the unique identity).
  """

  def run(repo) do
    rows =
      repo.query!("""
      SELECT c.id, c.user_id, unnest(c.approved_skill_ids) AS skill_id
      FROM conversations c
      WHERE c.approved_skill_ids IS NOT NULL
        AND array_length(c.approved_skill_ids, 1) > 0
      """)

    for [conv_id, user_id, skill_id] <- rows.rows do
      sha =
        case repo.query!("SELECT bundle_sha FROM skills WHERE id = $1", [skill_id]) do
          %{rows: [[sha]]} -> sha
          _ -> nil
        end

      repo.query!(
        """
        INSERT INTO conversation_skill_approvals
          (id, conversation_id, skill_id, bundle_sha, approved_by_id, source, inserted_at, updated_at)
        VALUES (uuid_generate_v7(), $1, $2, $3, $4, 'approval_card', now(), now())
        ON CONFLICT (conversation_id, skill_id) DO NOTHING
        """,
        [conv_id, skill_id, sha, user_id]
      )
    end

    :ok
  end
end
