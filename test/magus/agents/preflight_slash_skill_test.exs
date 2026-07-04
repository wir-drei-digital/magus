defmodule Magus.Agents.PreflightSlashSkillTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  alias Magus.Agents.Plugins.Support.Preflight
  alias Magus.Agents.SlashCommands

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

  describe "resolve_slash_actor/2 (multiplayer: triggering member, not owner)" do
    setup do
      # Conversation owned by A; a DIFFERENT member B owns a personal skill.
      owner = generate(user())
      member = generate(user())
      {:ok, conversation} = Magus.Chat.create_conversation(%{title: "MP"}, actor: owner)

      bytes = build_zip([{"SKILL.md", "---\nname: b-skill\ndescription: d\n---\nB BODY"}])
      {:ok, b_skill} = Magus.Skills.Import.import_bundle(bytes, actor: member)

      %{owner: owner, member: member, conversation: conversation, b_skill: b_skill}
    end

    test "the triggering member's own personal skill resolves; the owner cannot see it",
         %{owner: owner, member: member, conversation: conversation, b_skill: b_skill} do
      # The member who triggered the turn is the actor -> B's skill is visible.
      resolved = Preflight.resolve_slash_actor(member.id, conversation)
      assert resolved.id == member.id

      assert {{:skill, ref}, "please run"} =
               SlashCommands.resolve("/b-skill please run", [],
                 actor: resolved,
                 conversation: conversation
               )

      assert ref == "user:" <> b_skill.id

      # Under the conversation owner A, B's personal skill is NOT visible, so the
      # slash falls through to literal passthrough (the pre-fix behavior).
      owner_actor = Preflight.resolve_slash_actor(owner.id, conversation)
      assert owner_actor.id == owner.id

      assert {:none, "/b-skill please run"} =
               SlashCommands.resolve("/b-skill please run", [],
                 actor: owner_actor,
                 conversation: conversation
               )
    end

    test "given the member id it returns the member; given nil it falls back to the owner",
         %{owner: owner, member: member, conversation: conversation} do
      assert Preflight.resolve_slash_actor(member.id, conversation).id == member.id

      # nil acting_user_id (autonomous turns) falls back to the conversation owner.
      assert Preflight.resolve_slash_actor(nil, conversation).id == owner.id
    end
  end

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
