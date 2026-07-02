defmodule Magus.Agents.Tools.Skills.LoadSkillUserTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Skills.LoadSkill
  alias Magus.Skills

  defp conversation_for(owner) do
    # Minimal conversation owned by `owner`. Use the same creation path other
    # tool tests use; a chat conversation with default mode is sufficient.
    {:ok, conv} = Magus.Chat.create_conversation(%{title: "t"}, actor: owner)
    conv
  end

  test "loading a user skill by ref persists its body and requested tools" do
    owner = generate(user())
    conv = conversation_for(owner)

    {:ok, skill} =
      Skills.create_skill(
        %{
          name: "loadable",
          description: "d",
          body: "# Loadable\nDo the thing.",
          requested_tools: ["web_search"]
        },
        actor: owner
      )

    context = %{user_id: owner.id, user: owner, conversation_id: conv.id}

    {:ok, result} = LoadSkill.run(%{skill_name: "user:" <> skill.id}, context)
    assert result.content =~ "Do the thing."

    {:ok, reloaded} = Magus.Chat.get_conversation(conv.id, actor: owner)
    assert reloaded.skill_context =~ "Do the thing."
    assert "web_search" in (reloaded.skill_tools || [])
  end

  test "a non-owner cannot load another user's skill by ref" do
    owner = generate(user())
    stranger = generate(user())
    conv = conversation_for(stranger)

    {:ok, skill} =
      Skills.create_skill(%{name: "private-load", description: "d", body: "secret"}, actor: owner)

    context = %{user_id: stranger.id, user: stranger, conversation_id: conv.id}
    {:ok, result} = LoadSkill.run(%{skill_name: "user:" <> skill.id}, context)
    assert Map.has_key?(result, :error)
  end
end
