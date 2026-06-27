defmodule Magus.Agents.Tools.Skills.CreateSkillTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Skills.CreateSkill

  test "create_skill with no include_paths creates a prompt-only skill" do
    owner = generate(user())
    {:ok, conv} = Magus.Chat.create_conversation(%{title: "t"}, actor: owner)
    ctx = %{user_id: owner.id, user: owner, conversation_id: conv.id}

    {:ok, result} =
      CreateSkill.run(
        %{
          "name" => "authored",
          "description" => "made by agent",
          "body" => "# Authored",
          "include_paths" => nil
        },
        ctx
      )

    assert result.name == "authored"
    assert is_binary(result.skill_id)
  end
end
