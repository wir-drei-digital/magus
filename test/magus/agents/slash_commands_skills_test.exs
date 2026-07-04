defmodule Magus.Agents.SlashCommandsSkillsTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  alias Magus.Agents.SlashCommands

  test "resolves a user skill name to a skill ref, agent commands win, globals lose" do
    user = generate(user())

    bytes = build_zip([{"SKILL.md", "---\nname: my-skill\ndescription: d\n---\nb"}])
    {:ok, skill} = Magus.Skills.Import.import_bundle(bytes, actor: user)

    {result, remaining} =
      SlashCommands.resolve("/my-skill do the thing", [], actor: user, conversation: nil)

    assert {:skill, "user:" <> id} = result
    assert id == skill.id
    assert remaining == "do the thing"
  end

  test "unknown slash falls through to none with original text preserved" do
    user = generate(user())
    {result, remaining} = SlashCommands.resolve("/nope hi", [], actor: user, conversation: nil)
    assert result == :none
    assert remaining == "/nope hi"
  end

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
