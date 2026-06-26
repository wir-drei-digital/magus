defmodule Magus.LiveE2E.AutoRouterTest do
  @moduledoc """
  Tests for the intent classification auto-router with real LLM.
  Verifies ClassifyIntent action correctly categorizes queries.
  """
  use Magus.LiveE2ECase, async: false

  alias Magus.Agents.Actions.ClassifyIntent

  @moduletag :auto_router

  setup do
    # Enable real LLM classification (disabled by default in test config)
    original = Application.get_env(:magus, :agents)

    Application.put_env(
      :magus,
      :agents,
      Keyword.put(original || [], :classification_model, "openrouter:x-ai/grok-4.1-fast")
    )

    on_exit(fn ->
      Application.put_env(:magus, :agents, original || [])
    end)

    :ok
  end

  describe "intent classification" do
    test "classifies coding query correctly" do
      {:ok, result} =
        ClassifyIntent.run(
          %{text: "Write a Python function to sort a list of dictionaries by a specific key"},
          %{}
        )

      assert result.classification.intent == :coding,
             "Expected :coding intent, got: #{inspect(result.classification)}"

      assert result.classification.method == :llm,
             "Expected :llm method (real classification), got: #{result.classification.method}"
    end

    test "classifies general/chat query correctly" do
      {:ok, result} =
        ClassifyIntent.run(
          %{text: "Hello, how are you today?"},
          %{}
        )

      # Greetings should be classified via heuristic fast-path
      assert result.classification.intent in [:chat, :creative],
             "Expected :chat or :creative intent for greeting, got: #{inspect(result.classification)}"
    end

    test "classifies search query correctly" do
      {:ok, result} =
        ClassifyIntent.run(
          %{text: "What are the latest developments in quantum computing in 2026?"},
          %{}
        )

      assert result.classification.intent in [:search, :reasoning],
             "Expected :search or :reasoning for factual query, got: #{inspect(result.classification)}"
    end

    test "classifies reasoning query correctly" do
      {:ok, result} =
        ClassifyIntent.run(
          %{text: "Explain the mathematical proof of the Pythagorean theorem step by step"},
          %{}
        )

      assert result.classification.intent in [:reasoning, :coding],
             "Expected :reasoning or :coding for analytical query, got: #{inspect(result.classification)}"
    end
  end
end
