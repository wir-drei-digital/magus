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
end
