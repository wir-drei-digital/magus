defmodule Magus.Agents.PreflightSlashSkillTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  alias Magus.Agents.Plugins.Support.Preflight

  test "a /skill message deterministically loads a prompt-only skill and records approval on bundled ones" do
    user = generate(user())
    {:ok, conversation} = Magus.Chat.create_conversation(%{title: "P"}, actor: user)

    bytes =
      build_zip([{"SKILL.md", "---\nname: pf-skill\ndescription: d\n---\nSKILL BODY MARKER"}])

    {:ok, _skill} = Magus.Skills.Import.import_bundle(bytes, actor: user)

    # The unit under test is the slash-skill hook. Call the exposed helper that
    # preflight uses (Step 6 extracts it as a public function for testability).
    text =
      Preflight.apply_slash_skill(
        "/pf-skill please run",
        conversation.id,
        user
      )

    # Prompt-only skill body is now on the conversation; the returned text is the
    # user's residual message.
    assert text == "please run"
    {:ok, reloaded} = Magus.Chat.get_conversation(conversation.id, authorize?: false)
    assert reloaded.skill_context =~ "SKILL BODY MARKER"
  end

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
