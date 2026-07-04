defmodule Magus.Skills.ApprovalTest do
  use Magus.ResourceCase, async: true

  alias Magus.Skills.Approval
  alias Magus.Chat

  test "approved? reflects a recorded ConversationSkillApproval row" do
    owner = generate(user())
    {:ok, conv} = Chat.create_conversation(%{title: "t"}, actor: owner)

    bytes =
      build_zip([
        {"SKILL.md", "---\nname: approved-check\ndescription: D\n---\nb"},
        {"scripts/go.py", "x=1"}
      ])

    {:ok, skill} = Magus.Skills.Import.import_bundle(bytes, actor: owner)

    refute Approval.approved?(conv, skill)

    {:ok, _} =
      Magus.Skills.record_conversation_approval(
        %{
          conversation_id: conv.id,
          skill_id: skill.id,
          bundle_sha: skill.bundle_sha,
          approved_by_id: owner.id,
          source: :approval_card
        },
        actor: owner
      )

    assert Approval.approved?(conv, skill)
  end

  test "request/3 stores approve_phrase in notification metadata" do
    require Ash.Query

    owner = generate(user())
    {:ok, conv} = Chat.create_conversation(%{title: "approval test"}, actor: owner)

    bytes =
      build_zip([
        {"SKILL.md", "---\nname: test-phrase\ndescription: D\n---\n# Test\nDo stuff."}
      ])

    {:ok, skill} = Magus.Skills.Import.import_bundle(bytes, actor: owner)

    assert :ok = Approval.request(conv.id, skill, owner.id)

    expected_phrase = Approval.approve_phrase(skill.id)

    notifications =
      Magus.Notifications.Notification
      |> Ash.Query.filter(user_id == ^owner.id and notification_type == :approval_request)
      |> Ash.read!(authorize?: false)

    assert [notification] = notifications
    assert notification.metadata["approve_phrase"] == expected_phrase
    assert notification.metadata["skill_id"] == skill.id
  end

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
