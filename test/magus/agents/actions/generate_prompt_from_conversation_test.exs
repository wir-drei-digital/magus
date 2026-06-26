defmodule Magus.Agents.Actions.GeneratePromptFromConversationTest do
  @moduledoc """
  Tests for GeneratePromptFromConversation action.
  """
  use Magus.ResourceCase, async: true

  import Mox

  alias Magus.Agents.Actions.GeneratePromptFromConversation
  alias Magus.Test.Mocks.LLMMock
  alias Magus.Test.MockResponses

  setup :verify_on_exit!

  describe "action metadata" do
    test "has correct name" do
      assert GeneratePromptFromConversation.name() == "generate_prompt_from_conversation"
    end

    test "has description" do
      assert GeneratePromptFromConversation.description() =~ "prompt"
    end

    test "has required schema fields" do
      schema = GeneratePromptFromConversation.schema()

      # messages is required
      messages_opt = Keyword.get(schema, :messages)
      assert messages_opt[:required] == true
      assert messages_opt[:type] == {:list, :map}

      # model is optional
      model_opt = Keyword.get(schema, :model)
      assert model_opt[:required] != true
    end
  end

  describe "run/2" do
    test "generates prompt from conversation messages" do
      expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        MockResponses.generate_object_response(%{
          "content" => "Explain concepts in simple terms that anyone can understand.",
          "suggested_type" => "user",
          "suggested_name" => "Simple Explanations"
        })
      end)

      messages = [
        %{source: :user, text: "Can you explain this like I'm 5?"},
        %{source: :agent, text: "Sure! Let me break this down in simple terms..."},
        %{source: :user, text: "That makes sense! Can you always explain things simply?"},
        %{source: :agent, text: "Of course! I'll always try to use simple language."}
      ]

      {:ok, result} = GeneratePromptFromConversation.run(%{messages: messages}, %{})

      assert result.content =~ "simple"
      assert result.suggested_type == :user
      assert result.suggested_name == "Simple Explanations"
      assert is_map(result.usage)
    end

    test "generates system prompt from conversation messages" do
      expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        MockResponses.generate_object_response(%{
          "content" =>
            "You are a friendly assistant who uses analogies to explain complex concepts.",
          "suggested_type" => "system",
          "suggested_name" => "Analogy Teacher"
        })
      end)

      messages = [
        %{source: :user, text: "Use analogies when explaining things"},
        %{source: :agent, text: "Think of it like a river flowing..."}
      ]

      {:ok, result} = GeneratePromptFromConversation.run(%{messages: messages}, %{})

      assert result.suggested_type == :system
      assert result.suggested_name == "Analogy Teacher"
    end
  end
end
