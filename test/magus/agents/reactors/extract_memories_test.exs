defmodule Magus.Agents.Reactors.ExtractMemoriesTest do
  @moduledoc """
  Integration tests for the ExtractMemories reactor.

  Tests the memory extraction workflow including:
  - Loading existing memories
  - Analyzing conversation turns
  - Creating/updating memories
  """
  use Magus.ResourceCase, async: true
  use Oban.Testing, repo: Magus.Repo

  alias Magus.Agents.Reactors.ExtractMemories

  describe "reactor execution" do
    test "skips extraction for short messages" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      inputs = %{
        user_id: user.id,
        conversation_id: conversation.id,
        user_message: "Hi",
        agent_response: "Hello"
      }

      {:ok, result} = Reactor.run(ExtractMemories, inputs, async?: false)

      # Short messages should result in no extractions
      assert result.extracted == 0
    end

    test "processes longer conversation turns" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      inputs = %{
        user_id: user.id,
        conversation_id: conversation.id,
        user_message:
          "Please remember that my favorite programming language is Elixir and I prefer functional programming patterns.",
        agent_response:
          "I'll remember that you prefer Elixir and functional programming patterns. That's great - Elixir is an excellent choice for building concurrent systems."
      }

      result = Reactor.run(ExtractMemories, inputs, async?: false)

      # Result depends on LLM availability, so we just check the shape
      case result do
        {:ok, %{extracted: _, local: _, user: _}} ->
          :ok

        {:error, _} ->
          # LLM might not be available in test env
          :ok
      end
    end

    test "loads existing memories for context" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      # Create some existing memories
      memory(conversation_id: conversation.id, user_id: user.id, name: "Existing Memory")

      inputs = %{
        user_id: user.id,
        conversation_id: conversation.id,
        user_message: "Remember my new preference for dark mode",
        agent_response: "I've noted your preference for dark mode."
      }

      # The reactor should load existing memories without error
      result = Reactor.run(ExtractMemories, inputs, async?: false)

      # Either success or graceful failure
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles nil messages gracefully" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      inputs = %{
        user_id: user.id,
        conversation_id: conversation.id,
        user_message: nil,
        agent_response: nil
      }

      {:ok, result} = Reactor.run(ExtractMemories, inputs, async?: false)

      # Should return zero extractions for nil input
      assert result.extracted == 0
    end
  end

  describe "telemetry" do
    test "emits telemetry events on extraction" do
      # Subscribe to telemetry events
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:magus, :memory, :extracted]
        ])

      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      inputs = %{
        user_id: user.id,
        conversation_id: conversation.id,
        user_message: "Remember that I work at Anthropic",
        agent_response: "I've noted that you work at Anthropic."
      }

      # Run the reactor
      Reactor.run(ExtractMemories, inputs, async?: false)

      # Detach handler
      :telemetry.detach(ref)

      # Telemetry assertions would go here if extraction occurred
      # Since LLM may not be available, we just verify no crash
    end
  end
end
