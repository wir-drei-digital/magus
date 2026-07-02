defmodule Magus.Skills.DiscoveryLoadIntegrationTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Context.SystemPrompts
  alias Magus.Agents.Tools.Skills.LoadSkill
  alias Magus.Skills
  alias Magus.Skills.Discovery

  test "owner discovers a user skill, sees it in the prompt, and loads it by ref" do
    owner = generate(user())
    {:ok, conv} = Magus.Chat.create_conversation(%{title: "t"}, actor: owner)

    {:ok, skill} =
      Skills.create_skill(
        %{
          name: "e2e-skill",
          description: "End to end",
          body: "# E2E\nUse me.",
          requested_tools: ["web_search"]
        },
        actor: owner
      )

    # Discovery surfaces it with a stable ref.
    ref = "user:" <> skill.id
    assert ref in (Discovery.list_for_actor(owner) |> Enum.map(& &1.ref))

    # The prompt section shows the same ref.
    section = SystemPrompts.skills_capabilities(nil, owner)
    assert section =~ ref

    # Loading by that ref persists the body + tools.
    context = %{user_id: owner.id, user: owner, conversation_id: conv.id}
    {:ok, result} = LoadSkill.run(%{skill_name: ref}, context)
    assert result.content =~ "Use me."

    {:ok, reloaded} = Magus.Chat.get_conversation(conv.id, actor: owner)
    assert reloaded.skill_context =~ "Use me."
    assert "web_search" in (reloaded.skill_tools || [])
  end

  test "a stranger neither discovers nor loads the owner's private skill" do
    owner = generate(user())
    stranger = generate(user())
    {:ok, conv} = Magus.Chat.create_conversation(%{title: "t"}, actor: stranger)

    {:ok, skill} =
      Skills.create_skill(%{name: "e2e-private", description: "d", body: "nope"}, actor: owner)

    ref = "user:" <> skill.id

    refute ref in (Discovery.list_for_actor(stranger) |> Enum.map(& &1.ref))
    refute SystemPrompts.skills_capabilities(nil, stranger) =~ ref

    context = %{user_id: stranger.id, user: stranger, conversation_id: conv.id}
    assert {:ok, %{error: _}} = LoadSkill.run(%{skill_name: ref}, context)
  end
end
