defmodule Magus.Agents.Actions.GenerateTitleIntegrationTest do
  @moduledoc """
  Integration tests for GenerateTitle action.

  Tests the action with mocked LLM and real database operations:
  - Conversation creation
  - Message sending
  - Title generation via mocked LLM
  """
  use MagusWeb.LiveViewCase, async: false

  import Mox

  alias Magus.Agents.Actions.GenerateTitle
  alias Magus.Chat
  alias Magus.Test.Mocks.LLMMock
  alias Magus.Test.MockResponses

  setup :set_mox_global
  setup :verify_on_exit!

  describe "generate title integration" do
    test "generates title for conversation with messages" do
      expect(LLMMock, :generate_text, fn _model, _context, _opts ->
        MockResponses.generate_text_response("Travel Planning Discussion")
      end)

      messages = [
        %{source: :user, text: "I want to plan a trip to Japan"},
        %{source: :agent, text: "Great! Japan is a wonderful destination."}
      ]

      {:ok, result} = GenerateTitle.run(%{messages: messages}, %{})

      assert result.text == "Travel Planning Discussion"
      assert is_map(result.usage)
    end

    test "handles multilingual conversations" do
      expect(LLMMock, :generate_text, fn _model, _context, _opts ->
        MockResponses.generate_text_response("Japanreise Planung")
      end)

      messages = [
        %{source: :user, text: "Ich möchte eine Reise nach Japan planen"},
        %{source: :agent, text: "Wunderbar! Japan ist ein tolles Reiseziel."}
      ]

      {:ok, result} = GenerateTitle.run(%{messages: messages}, %{})

      assert result.text == "Japanreise Planung"
    end

    test "integrates with conversation generate_name action" do
      expect(LLMMock, :generate_text, fn _model, _context, _opts ->
        MockResponses.generate_text_response("Elixir Development Questions")
      end)

      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, _} =
        Chat.send_user_message(
          %{text: "How do I create a GenServer in Elixir?", conversation_id: conversation.id},
          actor: user
        )

      # Use the Ash action to generate name
      {:ok, updated} =
        Ash.Changeset.for_update(conversation, :generate_name, %{})
        |> Ash.update(authorize?: false)

      assert updated.title == "Elixir Development Questions"
    end
  end
end
