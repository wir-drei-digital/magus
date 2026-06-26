defmodule Magus.Agents.Actions.GenerateTitleTest do
  @moduledoc """
  Tests for GenerateTitle action.
  """
  use Magus.ResourceCase, async: true

  import Mox

  alias Magus.Agents.Actions.GenerateTitle
  alias Magus.Test.Mocks.LLMMock
  alias Magus.Test.MockResponses

  setup :verify_on_exit!

  describe "action metadata" do
    test "has correct name" do
      assert GenerateTitle.name() == "generate_title"
    end

    test "has description" do
      assert GenerateTitle.description() =~ "title"
    end

    test "has required schema fields" do
      schema = GenerateTitle.schema()

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
    test "generates title from messages" do
      expect(LLMMock, :generate_text, fn _model, _context, _opts ->
        MockResponses.generate_text_response("Sourdough Bread Recipe")
      end)

      messages = [
        %{source: :user, text: "How do I make sourdough bread?"},
        %{source: :agent, text: "Here's how to make sourdough..."}
      ]

      {:ok, result} = GenerateTitle.run(%{messages: messages}, %{})

      assert result.text == "Sourdough Bread Recipe"
      assert is_map(result.usage)
    end

    test "handles empty messages list" do
      expect(LLMMock, :generate_text, fn _model, _context, _opts ->
        MockResponses.generate_text_response("New Conversation")
      end)

      {:ok, result} = GenerateTitle.run(%{messages: []}, %{})

      assert result.text == "New Conversation"
    end
  end
end
