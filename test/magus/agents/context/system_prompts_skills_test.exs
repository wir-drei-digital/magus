defmodule Magus.Agents.Context.SystemPromptsSkillsTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Context.SystemPrompts
  alias Magus.Skills

  test "skills_capabilities/2 lists a user's skill with its user: ref" do
    owner = generate(user())

    {:ok, skill} =
      Skills.create_skill(%{name: "prompt-shown", description: "Shows up"}, actor: owner)

    section = SystemPrompts.skills_capabilities(nil, owner)
    assert section =~ "## Available Skills"
    assert section =~ "prompt-shown"
    assert section =~ "user:" <> skill.id
  end

  test "skills_capabilities/2 with a nil actor still lists built-in skills" do
    section = SystemPrompts.skills_capabilities(nil, nil)
    assert section =~ "## Available Skills"
    assert section =~ "builtin:"
  end
end
