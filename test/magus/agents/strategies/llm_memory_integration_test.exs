defmodule Magus.Agents.Strategies.LLMMemoryIntegrationTest do
  @moduledoc """
  Tests for the LLM strategy's integration with memory context.

  Note: These tests focus on the memory context request and extraction signal
  functionality without requiring actual LLM calls.
  """
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Actions.BuildMemoryContext
  alias Magus.Memory

  describe "message history building" do
    test "build_message_history returns flat message list without system prompt" do
      user = generate(user())
      conv = generate(conversation(actor: user))
      generate(message(actor: user, conversation_id: conv.id, text: "Hello"))

      messages = Magus.Chat.build_message_history!(conv.id, nil, false)

      assert is_list(messages)
      roles = Enum.map(messages, & &1.role)
      assert :user in roles
      refute :system in roles
    end

    test "build_message_history works with empty conversation" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      messages = Magus.Chat.build_message_history!(conv.id, nil, false)

      assert messages == []
    end
  end

  describe "BuildMemoryContext direct usage" do
    test "builds context with important memories" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      # Create a memory — it's key by being most recently updated
      {:ok, _memory} =
        Memory.create_memory(
          conv.id,
          user.id,
          "Local Memory",
          %{summary: "Conversation context"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      {:ok, context} =
        BuildMemoryContext.build(%{
          user_id: user.id,
          conversation_id: conv.id,
          query_text: "",
          global_enabled: true
        })

      assert length(context.important) == 1
      assert hd(context.important).name == "Local Memory"
      assert String.contains?(context.formatted, "Local Memory")
    end

    test "includes global memories when enabled" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      {:ok, _global_memory} =
        Memory.create_user_memory(
          user.id,
          nil,
          "Coding Style",
          %{summary: "Prefers functional patterns", content: %{"style" => "functional"}},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      {:ok, context} =
        BuildMemoryContext.build(%{
          user_id: user.id,
          conversation_id: conv.id,
          query_text: "",
          global_enabled: true
        })

      assert length(context.important) == 1
      assert hd(context.important).name == "Coding Style"
    end

    test "excludes global memories when disabled" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      {:ok, _global_memory} =
        Memory.create_user_memory(
          user.id,
          nil,
          "Hidden Global",
          %{summary: "Should not appear"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      {:ok, context} =
        BuildMemoryContext.build(%{
          user_id: user.id,
          conversation_id: conv.id,
          query_text: "",
          global_enabled: false
        })

      assert context.important == []
      assert context.global_enabled == false
    end
  end

  describe "memory retrieval" do
    test "memories are accessible for context building" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      {:ok, _local} =
        Memory.create_memory(
          conv.id,
          user.id,
          "Local Memory",
          %{summary: "Conversation context"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      {:ok, _global} =
        Memory.create_user_memory(
          user.id,
          nil,
          "Global Pref",
          %{summary: "User preferences"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      # Verify memories are retrievable via top recency lists
      {:ok, top_local} = Memory.list_top_local(conv.id, authorize?: false)
      {:ok, top_global} = Memory.list_top_user(nil, actor: user)

      assert length(top_local) == 1
      assert length(top_global) == 1
      assert hd(top_local).name == "Local Memory"
      assert hd(top_global).name == "Global Pref"
    end

    test "global memories respect user setting" do
      user = generate(user())

      # Disable global memory
      user
      |> Ash.Changeset.for_update(:update_global_memory_setting, %{global_memory_enabled: false},
        actor: user
      )
      |> Ash.update!()

      {:ok, updated_user} = Magus.Accounts.get_user(user.id, authorize?: false)

      assert updated_user.global_memory_enabled == false
    end
  end
end
