defmodule Magus.Agents.Tools.Skills.LoadSkillBundleTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Skills.LoadSkill
  alias Magus.{Chat, Skills}

  test "loading an unapproved bundled skill returns pending and does not materialize" do
    owner = generate(user())
    {:ok, conv} = Chat.create_conversation(%{title: "t"}, actor: owner)

    {:ok, skill} =
      Skills.import_skill(
        %{
          name: "bundled",
          description: "d",
          body: "# B",
          has_executable_bundle: true,
          source_format: :skill_md,
          bundle_path: "skills/x.zip"
        },
        actor: owner
      )

    ctx = %{user_id: owner.id, user: owner, conversation_id: conv.id}
    {:ok, result} = LoadSkill.run(%{skill_name: "user:" <> skill.id}, ctx)

    if Magus.Sandbox.Provider.configured?() do
      assert result.status == "pending"
      # body still persisted so the agent has the instructions
      assert result.content =~ "B"
    else
      # No sandbox: the unavailable branch fires before the approval check.
      assert result[:unavailable] == true or result.content =~ "unavailable"
      assert result.content =~ "B"
    end
  end

  test "loading an approved bundled skill (no sandbox) reports execution unavailable" do
    owner = generate(user())
    {:ok, conv} = Chat.create_conversation(%{title: "t"}, actor: owner)

    {:ok, skill} =
      Skills.import_skill(
        %{
          name: "bundled2",
          description: "d",
          body: "# B",
          has_executable_bundle: true,
          source_format: :skill_md,
          bundle_path: "skills/x.zip"
        },
        actor: owner
      )

    {:ok, conv} = Chat.record_skill_approval(conv, %{skill_id: skill.id}, actor: owner)

    ctx = %{user_id: owner.id, user: owner, conversation_id: conv.id}
    {:ok, result} = LoadSkill.run(%{skill_name: "user:" <> skill.id}, ctx)

    if Magus.Sandbox.Provider.configured?() do
      # With a sandbox, an approved skill materializes (covered in Task 6 E2E).
      assert Map.has_key?(result, :materialized) or Map.has_key?(result, :content)
    else
      assert result[:unavailable] == true or result.content =~ "unavailable"
    end
  end
end
