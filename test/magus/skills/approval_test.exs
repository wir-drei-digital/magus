defmodule Magus.Skills.ApprovalTest do
  use Magus.ResourceCase, async: true

  alias Magus.Skills.Approval
  alias Magus.Chat

  test "approved? reflects the conversation's approved_skill_ids" do
    owner = generate(user())
    {:ok, conv} = Chat.create_conversation(%{title: "t"}, actor: owner)
    id = Ecto.UUID.generate()

    refute Approval.approved?(conv, id)
    {:ok, conv} = Chat.record_skill_approval(conv, %{skill_id: id}, actor: owner)
    assert Approval.approved?(conv, id)
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
