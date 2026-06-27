defmodule Magus.Agents.Tools.Skills.LoadSkillTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Tools.Skills.LoadSkill

  describe "display_name/0" do
    test "returns display string" do
      assert LoadSkill.display_name() == "Loading skill..."
    end
  end

  describe "summarize_output/1" do
    test "summarizes successful skill load" do
      output = %{skill: "poetry_writing"}
      assert LoadSkill.summarize_output(output) == "Loaded: poetry_writing"
    end

    test "summarizes skill not found" do
      output = %{error: "Skill not found"}
      assert LoadSkill.summarize_output(output) == "Skill not found"
    end

    test "summarizes unknown output" do
      assert LoadSkill.summarize_output(%{}) == "Completed"
    end
  end

  describe "run/2" do
    test "returns skill content when skill exists" do
      params = %{skill_name: "poetry_writing"}
      assert {:ok, result} = LoadSkill.run(params, %{})

      assert result.skill == "poetry_writing"
      assert is_binary(result.content)
      assert result.content =~ "Poetry"
      assert is_binary(result.description)
    end

    test "returns error with available skills when skill not found" do
      params = %{skill_name: "nonexistent_skill"}
      assert {:ok, result} = LoadSkill.run(params, %{})

      assert result.error =~ "not found"
      assert is_list(result.available_skills)
      assert "builtin:poetry_writing" in result.available_skills
    end

    test "can load multiple different skills" do
      params1 = %{skill_name: "poetry_writing"}
      params2 = %{skill_name: "coding"}

      assert {:ok, result1} = LoadSkill.run(params1, %{})
      assert {:ok, result2} = LoadSkill.run(params2, %{})

      assert result1.skill == "poetry_writing"
      assert result2.skill == "coding"
      assert result1.content != result2.content
    end
  end
end
