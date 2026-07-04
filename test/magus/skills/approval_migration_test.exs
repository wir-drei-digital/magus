defmodule Magus.Skills.ApprovalMigrationTest do
  use Magus.DataCase, async: false
  import Magus.Generators

  alias Magus.Repo

  test "backfill copies array approvals into join rows with the skill's sha" do
    user = generate(user())
    {:ok, conversation} = Magus.Chat.create_conversation(%{title: "M"}, actor: user)

    bytes =
      build_zip([
        {"SKILL.md", "---\nname: mig-skill\ndescription: d\n---\nb"},
        {"scripts/go.py", "x=1"}
      ])

    {:ok, skill} = Magus.Skills.Import.import_bundle(bytes, actor: user)

    # The legacy `approved_skill_ids` column is dropped by the structural
    # migration, so re-create it here to drive the backfill against the real
    # tables. The sandbox rolls this DDL back, and we drop it explicitly too.
    Repo.query!("ALTER TABLE conversations ADD COLUMN IF NOT EXISTS approved_skill_ids uuid[]")

    try do
      # Simulate a legacy row: write the array column directly.
      Repo.query!(
        "UPDATE conversations SET approved_skill_ids = $1 WHERE id = $2",
        [[Ecto.UUID.dump!(skill.id)], Ecto.UUID.dump!(conversation.id)]
      )

      Magus.Skills.Migrations.BackfillApprovals.run(Repo)
    after
      Repo.query!("ALTER TABLE conversations DROP COLUMN IF EXISTS approved_skill_ids")
    end

    rows =
      Magus.Skills.ConversationSkillApproval
      |> Ash.read!(authorize?: false)
      |> Enum.filter(&(&1.conversation_id == conversation.id))

    assert [row] = rows
    assert row.skill_id == skill.id
    assert row.bundle_sha == skill.bundle_sha
    assert row.source == :approval_card
    assert row.approved_by_id == user.id
  end

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
