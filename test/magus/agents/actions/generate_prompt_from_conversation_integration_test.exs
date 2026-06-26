defmodule Magus.Agents.Actions.GeneratePromptFromConversationIntegrationTest do
  @moduledoc """
  Integration tests for GeneratePromptFromConversation action.

  Tests the action with mocked LLM and real database operations:
  - Conversation creation
  - Message history building
  - Prompt extraction via mocked LLM
  """
  use MagusWeb.LiveViewCase, async: false

  import Mox

  alias Magus.Agents.Actions.GeneratePromptFromConversation
  alias Magus.Library
  alias Magus.Chat
  alias Magus.Test.Mocks.LLMMock
  alias Magus.Test.MockResponses

  setup :set_mox_global
  setup :verify_on_exit!

  describe "generate prompt from conversation integration" do
    test "extracts system prompt pattern from conversation" do
      expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        MockResponses.generate_object_response(%{
          "content" =>
            "You are an expert code reviewer who provides detailed, constructive feedback.",
          "suggested_type" => "system",
          "suggested_name" => "Code Review Expert"
        })
      end)

      messages = [
        %{source: :user, text: "Can you review my code?"},
        %{source: :agent, text: "I'll analyze your code for issues and best practices."}
      ]

      {:ok, result} = GeneratePromptFromConversation.run(%{messages: messages}, %{})

      assert result.suggested_type == :system
      assert result.suggested_name == "Code Review Expert"
      assert result.content =~ "code reviewer"
    end

    test "extracts user prompt pattern from conversation" do
      expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        MockResponses.generate_object_response(%{
          "content" => "Write a blog post about {{TOPIC}} in an engaging style.",
          "suggested_type" => "user",
          "suggested_name" => "Blog Post Template"
        })
      end)

      messages = [
        %{source: :user, text: "Write a blog post about AI"},
        %{source: :agent, text: "Here's a blog post about AI and its impact..."}
      ]

      {:ok, result} = GeneratePromptFromConversation.run(%{messages: messages}, %{})

      assert result.suggested_type == :user
      assert result.suggested_name == "Blog Post Template"
    end

    test "integrates with Library.create_prompt_from_conversation" do
      expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        MockResponses.generate_object_response(%{
          "content" => "Explain technical concepts using everyday analogies.",
          "suggested_type" => "system",
          "suggested_name" => "Analogy Explainer"
        })
      end)

      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, _} =
        Chat.send_user_message(
          %{
            text: "Can you explain recursion using a real-world analogy?",
            conversation_id: conversation.id
          },
          actor: user
        )

      {:ok, prompt} =
        Library.create_prompt_from_conversation(
          conversation.id,
          %{},
          actor: user
        )

      assert prompt.name == "Analogy Explainer"
      assert prompt.type == :system
      assert prompt.content =~ "analogies"
      assert prompt.user_id == user.id
    end

    test "handles complex multi-turn conversations" do
      expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        MockResponses.generate_object_response(%{
          "content" =>
            "Break down complex problems into step-by-step solutions with clear explanations.",
          "suggested_type" => "system",
          "suggested_name" => "Step-by-Step Teacher"
        })
      end)

      messages = [
        %{source: :user, text: "How do I solve this math problem?"},
        %{source: :agent, text: "Let me break this down step by step..."},
        %{source: :user, text: "Can you break it down step by step?"},
        %{source: :agent, text: "Step 1: First we need to..."},
        %{source: :user, text: "That makes sense! Can you always explain things this way?"},
        %{source: :agent, text: "Of course! I'll always provide step-by-step explanations."}
      ]

      {:ok, result} = GeneratePromptFromConversation.run(%{messages: messages}, %{})

      assert result.suggested_type == :system
      assert result.suggested_name == "Step-by-Step Teacher"
    end
  end
end
