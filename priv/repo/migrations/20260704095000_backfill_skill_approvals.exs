defmodule Magus.Repo.Migrations.BackfillSkillApprovals do
  @moduledoc """
  Data-only migration: copy legacy `conversations.approved_skill_ids` arrays into
  `conversation_skill_approvals` rows. Runs after `conversation_skill_approvals`
  exists (20260704094234) and before `approved_skill_ids` is dropped (the next
  generated migration).
  """

  use Ecto.Migration

  def up do
    Magus.Skills.Migrations.BackfillApprovals.run(repo())
  end

  def down, do: :ok
end
