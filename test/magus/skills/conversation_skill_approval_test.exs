defmodule Magus.Skills.ConversationSkillApprovalTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  alias Magus.Skills.Approval

  setup do
    user = generate(user())
    {:ok, conversation} = Magus.Chat.create_conversation(%{title: "A"}, actor: user)

    bytes =
      build_zip([
        {"SKILL.md", "---\nname: gate-skill\ndescription: d\n---\nb"},
        {"scripts/go.py", "x=1"}
      ])

    {:ok, skill} = Magus.Skills.Import.import_bundle(bytes, actor: user)
    %{user: user, conversation: conversation, skill: skill}
  end

  test "unapproved skill is not approved?", %{conversation: c, skill: s} do
    refute Approval.approved?(c, s)
  end

  test "recording an approval makes approved? true", %{user: u, conversation: c, skill: s} do
    {:ok, _} =
      Magus.Skills.record_conversation_approval(
        %{
          conversation_id: c.id,
          skill_id: s.id,
          bundle_sha: s.bundle_sha,
          approved_by_id: u.id,
          source: :approval_card
        },
        actor: u
      )

    {:ok, c2} = Magus.Chat.get_conversation(c.id, authorize?: false)
    assert Approval.approved?(c2, s)
  end

  test "a bundle_sha change re-gates a previously approved skill",
       %{user: u, conversation: c, skill: s} do
    {:ok, _} =
      Magus.Skills.record_conversation_approval(
        %{
          conversation_id: c.id,
          skill_id: s.id,
          bundle_sha: s.bundle_sha,
          approved_by_id: u.id,
          source: :approval_card
        },
        actor: u
      )

    changed = %{s | bundle_sha: "deadbeef"}
    {:ok, c2} = Magus.Chat.get_conversation(c.id, authorize?: false)
    refute Approval.approved?(c2, changed)
  end

  test "deleting a non-owner approver nilifies approved_by_id, keeping the row",
       %{user: owner, conversation: c, skill: s} do
    approver = generate(user())

    {:ok, approval} =
      Magus.Skills.record_conversation_approval(
        %{
          conversation_id: c.id,
          skill_id: s.id,
          bundle_sha: s.bundle_sha,
          approved_by_id: approver.id,
          source: :approval_card
        },
        authorize?: false
      )

    assert approval.approved_by_id == approver.id
    # Sanity: the approver is a different user than the conversation owner.
    refute approver.id == owner.id

    # Mirror the account-deletion flow (Magus.Accounts.AccountDeletion drops the
    # User row directly via Ecto). A missing on_delete on approved_by_id would
    # abort this transaction; :nilify keeps the approval and forgets the approver.
    Magus.Repo.delete!(approver)

    {:ok, reloaded} =
      Ash.get(Magus.Skills.ConversationSkillApproval, approval.id, authorize?: false)

    assert reloaded.approved_by_id == nil
  end

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
