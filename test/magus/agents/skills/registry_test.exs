defmodule Magus.Agents.Skills.RegistryTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Skills.Registry

  # Note: These tests rely on the registry being started by the application
  # and the skill files in priv/skills/ existing

  describe "list_skills/0" do
    test "returns list of skills without content" do
      skills = Registry.list_skills()
      assert is_list(skills)

      # We have at least our example skills (poetry, debugging, technical writing, workflow)
      assert length(skills) >= 4

      # Skills should not include content (for memory efficiency)
      for skill <- skills do
        assert is_nil(skill.content)
        assert is_binary(skill.name)
        assert is_binary(skill.description)
        assert is_list(skill.tools)
      end
    end
  end

  describe "get_skill/1" do
    test "returns skill with content when found" do
      assert {:ok, skill} = Registry.get_skill("poetry_writing")
      assert skill.name == "poetry_writing"
      assert is_binary(skill.content)
      assert skill.content =~ "Poetry"
      assert is_binary(skill.description)
      assert is_list(skill.tags)
    end

    test "returns error when skill not found" do
      assert {:error, :not_found} = Registry.get_skill("nonexistent_skill")
    end

    test "returns tools declared in frontmatter" do
      assert {:ok, skill} = Registry.get_skill("interest_profile_wizard")
      assert is_list(skill.tools)
      assert "web_search" in skill.tools
    end

    test "returns empty tools list when skill has no tools declared" do
      assert {:ok, skill} = Registry.get_skill("poetry_writing")
      assert skill.tools == []
    end
  end

  describe "has_skills?/0" do
    test "returns true when skills exist" do
      assert Registry.has_skills?() == true
    end
  end

  describe "skill_index_text/0" do
    test "returns formatted text with skill names and descriptions" do
      text = Registry.skill_index_text()
      assert is_binary(text)

      # Should contain our example skills
      assert text =~ "poetry_writing"
      assert text =~ "technical_writing"

      # Should be formatted as markdown list
      assert text =~ "- **"
    end
  end

  describe "get_skills_section/0" do
    test "returns formatted section for system prompt" do
      section = Registry.get_skills_section()
      assert is_binary(section)

      # Should have header
      assert section =~ "## Available Skills"

      # Should have instructions
      assert section =~ "load_skill"

      # Should contain skill index
      assert section =~ "poetry_writing"
    end
  end

  describe "reload/0" do
    test "reloads skills from disk" do
      # Get current skills count
      initial_count = length(Registry.list_skills())

      # Reload should succeed
      assert :ok = Registry.reload()

      # Should still have same number of skills
      reloaded_count = length(Registry.list_skills())
      assert reloaded_count == initial_count
    end
  end
end
