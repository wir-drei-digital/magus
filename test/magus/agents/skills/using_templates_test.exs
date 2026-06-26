defmodule Magus.Agents.Skills.UsingTemplatesTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Skills.Registry

  setup do
    Registry.reload()
    :ok
  end

  test "skill is discoverable by name" do
    assert {:ok, skill} = Registry.get_skill("using_templates")
    assert is_binary(skill.content) and skill.content != ""
    assert skill.description =~ "template"
  end

  test "skill content covers the supported formats" do
    {:ok, skill} = Registry.get_skill("using_templates")

    for format <- [".docx", ".pptx", ".xlsx", ".pdf", "image"] do
      assert String.contains?(skill.content, format),
             "skill content should mention #{format}"
    end
  end
end
