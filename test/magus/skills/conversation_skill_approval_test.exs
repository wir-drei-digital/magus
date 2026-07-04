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

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
