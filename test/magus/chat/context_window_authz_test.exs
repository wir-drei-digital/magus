defmodule Magus.Chat.ContextWindowAuthzTest do
  @moduledoc """
  Authorization tests for the context-window read policy.

  Verifies the read-only-donut decision: accepted multiplayer members (and
  workspace grantees) can READ the window so the donut renders for them, while
  non-members cannot, and all mutating actions stay owner-only.
  """
  use Magus.ResourceCase, async: true
  require Ash.Query

  alias Magus.Agents.Support.AiAgent
  alias Magus.Chat

  setup do
    owner = generate(user())
    {:ok, conv} = Chat.create_conversation(%{title: "shared"}, actor: owner)
    {:ok, _} = Chat.enable_multiplayer(conv, actor: owner)
    # Seed the window so a read returns a concrete row (donut data).
    {:ok, _cw} = Chat.get_or_create_context_window(conv.id, actor: %AiAgent{})
    %{owner: owner, conv: conv}
  end

  defp accepted_member(conv, owner) do
    member = generate(user())

    {:ok, membership} =
      Chat.add_conversation_member(conv.id, member.id, %{invited_by_id: owner.id},
        authorize?: false
      )

    {:ok, _} = Chat.accept_conversation_invitation(membership, actor: member)
    member
  end

  describe "read policy" do
    test "owner can read the context window", %{owner: owner, conv: conv} do
      assert {:ok, cw} = Chat.get_context_window(conv.id, actor: owner)
      assert cw.conversation_id == conv.id
    end

    test "accepted member can read the context window", %{owner: owner, conv: conv} do
      member = accepted_member(conv, owner)

      assert {:ok, cw} = Chat.get_context_window(conv.id, actor: member)
      assert cw.conversation_id == conv.id
    end

    test "non-member cannot read the context window", %{conv: conv} do
      stranger = generate(user())

      assert {:error, _} = Chat.get_context_window(conv.id, actor: stranger)
    end

    test "pending (unaccepted) member cannot read the context window", %{owner: owner, conv: conv} do
      member = generate(user())

      {:ok, _membership} =
        Chat.add_conversation_member(conv.id, member.id, %{invited_by_id: owner.id},
          authorize?: false
        )

      assert {:error, _} = Chat.get_context_window(conv.id, actor: member)
    end
  end

  describe "mutating actions stay owner-only" do
    test "accepted member cannot clear the window", %{owner: owner, conv: conv} do
      member = accepted_member(conv, owner)

      assert {:error, _} = Chat.clear_context_for_conversation(conv.id, actor: member)
    end

    test "accepted member cannot request compaction", %{owner: owner, conv: conv} do
      member = accepted_member(conv, owner)

      assert {:error, _} = Chat.compact_context_for_conversation(conv.id, actor: member)
    end

    test "accepted member cannot set the strategy", %{owner: owner, conv: conv} do
      member = accepted_member(conv, owner)

      assert {:error, _} =
               Chat.set_context_strategy_for_conversation(conv.id, :compact, actor: member)
    end

    test "owner can still clear the window", %{owner: owner, conv: conv} do
      assert {:ok, _cw} = Chat.clear_context_for_conversation(conv.id, actor: owner)
    end
  end
end
