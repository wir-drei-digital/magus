defmodule Magus.Agents.Actions.ClassifyIntentTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Actions.ClassifyIntent
  alias Magus.Agents.Routing.AutoRouter.Classification

  defp classify(text, extra \\ %{}) do
    {:ok, %{classification: result}} =
      ClassifyIntent.run(Map.merge(%{text: text}, extra), %{})

    result
  end

  describe "greetings (fast path)" do
    test "English greetings → simple chat" do
      for greeting <- ["Hi", "Hello!", "Hey", "Howdy", "Good morning"] do
        result = classify(greeting)
        assert %Classification{intent: :chat, complexity: :simple, method: :heuristic} = result
        assert result.confidence >= 0.9
      end
    end

    test "German greetings → simple chat" do
      for greeting <- ["Hallo", "Moin", "Servus", "Guten Tag", "Guten Morgen"] do
        result = classify(greeting)
        assert %Classification{intent: :chat, complexity: :simple, method: :heuristic} = result
      end
    end

    test "French greetings → simple chat" do
      for greeting <- ["Salut", "Bonjour", "Bonsoir", "Coucou"] do
        result = classify(greeting)
        assert %Classification{intent: :chat, complexity: :simple, method: :heuristic} = result
      end
    end

    test "thank you messages → simple chat" do
      for msg <- ["Thanks!", "Thank you", "Danke", "Merci"] do
        result = classify(msg)
        assert %Classification{intent: :chat, complexity: :simple, method: :heuristic} = result
      end
    end
  end

  describe "search mode override (fast path)" do
    test "search mode forces search intent" do
      result = classify("tell me about cats", %{mode: :search})
      assert %Classification{intent: :search, confidence: 1.0, method: :heuristic} = result
    end
  end

  describe "no model configured" do
    test "defaults to chat with zero confidence" do
      # classification_model is nil in test env
      result = classify("Help me debug this function")
      assert %Classification{intent: :chat, method: :heuristic} = result
      assert result.confidence == 0.0
    end
  end

  describe "complexity estimation" do
    test "short messages → simple" do
      result = classify("What is Elixir?")
      assert result.complexity == :simple
    end

    test "messages with multiple questions → medium or hard" do
      result =
        classify("What is Elixir? How does it compare to Go? Which should I learn first?")

      assert result.complexity in [:medium, :hard]
    end

    test "long detailed messages → hard" do
      long_text = String.duplicate("Please analyze this complex problem in detail. ", 50)
      result = classify(long_text)
      assert result.complexity == :hard
    end

    test "messages with code blocks → medium or hard" do
      msg = "Fix this:\n```\ndef broken do\n  nil\nend\n```"
      result = classify(msg)
      assert result.complexity in [:medium, :hard]
    end
  end
end

defmodule Magus.Agents.Actions.ClassifyIntentLLMTest do
  use ExUnit.Case, async: false

  import Mox

  alias Magus.Agents.Actions.ClassifyIntent
  alias Magus.Agents.Routing.AutoRouter.Classification
  alias Magus.Test.MockResponses

  setup :verify_on_exit!

  setup do
    original = Application.get_env(:magus, :agents, [])
    agents_config = Keyword.put(original, :classification_model, "openrouter:test/model")
    Application.put_env(:magus, :agents, agents_config)

    on_exit(fn ->
      Application.put_env(:magus, :agents, original)
    end)

    :ok
  end

  defp classify(text, extra \\ %{}) do
    {:ok, %{classification: result}} =
      ClassifyIntent.run(Map.merge(%{text: text}, extra), %{})

    result
  end

  defp mock_classification(intent, confidence) do
    expect(Magus.Test.Mocks.LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
      MockResponses.generate_object_response(%{
        "intent" => to_string(intent),
        "confidence" => confidence
      })
    end)
  end

  describe "LLM intent detection" do
    test "coding intent" do
      mock_classification(:coding, 0.92)

      result = classify("Help me write a GenServer")
      assert %Classification{intent: :coding, method: :llm} = result
      assert_in_delta result.confidence, 0.92, 0.01
    end

    test "search intent" do
      mock_classification(:search, 0.95)

      result = classify("What is the weather in Berlin?")
      assert %Classification{intent: :search, method: :llm} = result
    end

    test "reasoning intent" do
      mock_classification(:reasoning, 0.88)

      result = classify("Prove the Pythagorean theorem")
      assert %Classification{intent: :reasoning, method: :llm} = result
    end

    test "creative intent" do
      mock_classification(:creative, 0.91)

      result = classify("Write me a poem about autumn")
      assert %Classification{intent: :creative, method: :llm} = result
    end

    test "chat intent" do
      mock_classification(:chat, 0.85)

      result = classify("What do you think about AI?")
      assert %Classification{intent: :chat, method: :llm} = result
    end
  end

  describe "LLM error handling" do
    test "falls back to default on LLM error" do
      expect(Magus.Test.Mocks.LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        {:error, %{error: "service unavailable"}}
      end)

      result = classify("Help me debug this function")
      assert %Classification{intent: :chat, method: :heuristic} = result
      assert result.confidence == 0.0
    end

    test "falls back to default when LLM returns non-map object" do
      expect(Magus.Test.Mocks.LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        {:ok, %{object: nil, usage: %{input_tokens: 5, output_tokens: 5}}}
      end)

      result = classify("Something")
      assert %Classification{intent: :chat, method: :heuristic} = result
      assert result.confidence == 0.0
    end

    test "defaults to chat for invalid intent string" do
      expect(Magus.Test.Mocks.LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        MockResponses.generate_object_response(%{
          "intent" => "unknown_intent",
          "confidence" => 0.8
        })
      end)

      result = classify("Something unusual")
      assert result.intent == :chat
      assert result.method == :llm
    end

    test "clamps confidence to 0-1 range" do
      expect(Magus.Test.Mocks.LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        MockResponses.generate_object_response(%{
          "intent" => "chat",
          "confidence" => 1.5
        })
      end)

      result = classify("Hello there")
      assert result.confidence == 1.0
    end
  end

  describe "fast paths bypass LLM" do
    test "greetings bypass LLM even when configured" do
      # No mock expectation — LLM should not be called
      result = classify("Hello!")
      assert %Classification{intent: :chat, method: :heuristic} = result
    end

    test "search mode bypasses LLM even when configured" do
      # No mock expectation — LLM should not be called
      result = classify("anything", %{mode: :search})
      assert %Classification{intent: :search, method: :heuristic} = result
    end
  end

  describe "LLM call contract" do
    test "passes correct model, schema, and system prompt" do
      expect(Magus.Test.Mocks.LLMMock, :generate_object, fn model, prompt, schema, opts ->
        assert model == "openrouter:test/model"
        assert is_binary(prompt)

        assert schema["properties"]["intent"]["enum"] == [
                 "coding",
                 "search",
                 "reasoning",
                 "creative",
                 "chat"
               ]

        assert Keyword.has_key?(opts, :system_prompt)

        MockResponses.generate_object_response(%{
          "intent" => "chat",
          "confidence" => 0.7
        })
      end)

      classify("Tell me about Elixir")
    end

    test "complexity is always estimated from text structure, not LLM" do
      mock_classification(:coding, 0.9)

      long_text =
        "Debug this complex issue:\n```\ndef broken do\n  nil\nend\n```\n\nAlso check the tests."

      result = classify(long_text)
      assert result.complexity in [:medium, :hard]
      assert result.method == :llm
    end
  end
end
