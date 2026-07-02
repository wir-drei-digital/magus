defmodule Magus.Chat.ConversationSkillApprovalTest do
  use Magus.ResourceCase, async: true

  alias Magus.Chat

  test "record_skill_approval appends a skill id without duplicates" do
    owner = generate(user())
    {:ok, conv} = Chat.create_conversation(%{title: "t"}, actor: owner)
    id = Ecto.UUID.generate()

    {:ok, c1} = Chat.record_skill_approval(conv, %{skill_id: id}, actor: owner)
    assert id in c1.approved_skill_ids

    {:ok, c2} = Chat.record_skill_approval(c1, %{skill_id: id}, actor: owner)
    assert Enum.count(c2.approved_skill_ids, &(&1 == id)) == 1
  end
end
