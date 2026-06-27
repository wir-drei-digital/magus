defmodule Magus.Skills.SkillTest do
  use Magus.ResourceCase, async: true

  alias Magus.Skills

  describe "create/read as owner" do
    setup do
      owner = generate(user())
      %{owner: owner}
    end

    test "owner creates and reads a personal skill", %{owner: owner} do
      {:ok, skill} =
        Skills.create_skill(
          %{name: "pdf-filler", description: "Fill PDF forms", body: "# PDF\n"},
          actor: owner
        )

      assert skill.name == "pdf-filler"
      assert skill.source_format == :skill_md
      assert skill.has_executable_bundle == false
      assert {:ok, fetched} = Skills.get_skill(skill.id, actor: owner)
      assert fetched.id == skill.id
    end

    test "owner updates the body", %{owner: owner} do
      {:ok, skill} =
        Skills.create_skill(%{name: "note-taker", description: "Notes"}, actor: owner)

      {:ok, updated} = Skills.update_skill(skill, %{body: "# Notes\nUse markdown."}, actor: owner)
      assert updated.body == "# Notes\nUse markdown."
    end

    test "rejects an invalid name", %{owner: owner} do
      assert {:error, %Ash.Error.Invalid{}} =
               Skills.create_skill(%{name: "Bad Name!", description: "x"}, actor: owner)
    end
  end

  describe "ownership isolation" do
    test "a non-owner cannot read a personal skill" do
      owner = generate(user())
      stranger = generate(user())

      {:ok, skill} =
        Skills.create_skill(%{name: "secret-skill", description: "x"}, actor: owner)

      assert {:error, _} = Skills.get_skill(skill.id, actor: stranger)
    end
  end
end
