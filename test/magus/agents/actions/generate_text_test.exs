defmodule Magus.Agents.Actions.GenerateTextTest do
  @moduledoc """
  Tests for the simplified GenerateText action.

  GenerateText is a generic LLM streaming action. The agentic loop (tool execution)
  is handled by the LLM strategy, not this action.
  """
  use Magus.ResourceCase, async: false

  import Mox

  alias Magus.Agents.Actions.GenerateText
  alias Magus.Test.Mocks.LLMMock
  alias Magus.Test.MockResponses

  setup :verify_on_exit!

  # Mock tool module for testing build_tools_from_actions
  defmodule TestTool do
    @moduledoc false
    use Jido.Action,
      name: "test_tool",
      description: "A test tool",
      schema: [
        query: [type: :string, required: true, doc: "Search query"]
      ]

    @impl true
    def run(_params, _context), do: {:ok, %{result: "test result"}}
  end

  describe "action metadata" do
    test "has correct name" do
      assert GenerateText.name() == "generate_text"
    end

    test "has description" do
      assert GenerateText.description() =~ "streaming"
    end

    test "has required schema fields" do
      schema = GenerateText.schema()

      # model is required
      model_opt = Keyword.get(schema, :model)
      assert model_opt[:required] == true
      assert model_opt[:type] == :string

      # messages is required
      messages_opt = Keyword.get(schema, :messages)
      assert messages_opt[:required] == true
    end

    test "has optional schema fields" do
      schema = GenerateText.schema()

      # tools is optional with default
      tools_opt = Keyword.get(schema, :tools)
      assert tools_opt[:default] == []

      # sampling parameters are optional
      temp_opt = Keyword.get(schema, :temperature)
      assert temp_opt[:default] == nil
    end
  end

  describe "run/2" do
    test "generates streaming text response" do
      expect(LLMMock, :stream_text, fn _model, _context, _opts ->
        MockResponses.stream_text_response("Hello! How can I help you today?")
      end)

      params = %{
        model: "openrouter:google/gemini-2.0-flash",
        messages: ReqLLM.Context.new([ReqLLM.Context.user("Hello")]),
        tools: []
      }

      {:ok, result} = GenerateText.run(params, %{})

      # Result includes text, tool_calls, usage, and chunks
      assert result.text == "Hello! How can I help you today?"
      assert result.tool_calls == []
      assert result.usage != nil
      assert is_list(result.chunks)
    end

    test "returns tool calls without executing them" do
      # GenerateText returns tool calls but does NOT execute them
      # That's the caller's (strategy's) responsibility
      expect(LLMMock, :stream_text, fn _model, _context, _opts ->
        MockResponses.stream_text_with_tool_call(
          "Let me search for that.",
          "web_search",
          %{"query" => "test"}
        )
      end)

      params = %{
        model: "openrouter:google/gemini-2.0-flash",
        messages: ReqLLM.Context.new([ReqLLM.Context.user("Search for something")])
      }

      {:ok, result} = GenerateText.run(params, %{})

      # Text from the LLM before tool call
      assert result.text == "Let me search for that."

      # Tool calls are returned but NOT executed
      assert length(result.tool_calls) == 1
      [tool_call] = result.tool_calls
      assert tool_call.name == "web_search"
      assert tool_call.arguments == %{"query" => "test"}
    end

    test "calls on_chunk callback for each chunk" do
      expect(LLMMock, :stream_text, fn _model, _context, _opts ->
        MockResponses.stream_text_response("Hello world")
      end)

      {:ok, chunks_seen} = Agent.start_link(fn -> [] end)

      params = %{
        model: "openrouter:google/gemini-2.0-flash",
        messages: ReqLLM.Context.new([ReqLLM.Context.user("Hi")]),
        on_chunk: fn chunk, accumulated ->
          Agent.update(chunks_seen, fn list -> [{chunk.text, accumulated} | list] end)
        end
      }

      {:ok, result} = GenerateText.run(params, %{})

      chunks = Agent.get(chunks_seen, & &1) |> Enum.reverse()
      Agent.stop(chunks_seen)

      # Each chunk callback received the delta and accumulated text
      assert length(chunks) > 0
      assert result.text == "Hello world"
    end

    test "passes sampling parameters to LLM" do
      expect(LLMMock, :stream_text, fn _model, _context, opts ->
        # Verify sampling params were passed
        assert opts[:temperature] == 0.7
        assert opts[:max_tokens] == 100
        MockResponses.stream_text_response("Response")
      end)

      params = %{
        model: "openrouter:google/gemini-2.0-flash",
        messages: ReqLLM.Context.new([ReqLLM.Context.user("Hi")]),
        temperature: 0.7,
        max_tokens: 100
      }

      {:ok, _result} = GenerateText.run(params, %{})
    end

    test "handles LLM errors" do
      expect(LLMMock, :stream_text, fn _model, _context, _opts ->
        {:error, %{message: "API error"}}
      end)

      params = %{
        model: "openrouter:google/gemini-2.0-flash",
        messages: ReqLLM.Context.new([ReqLLM.Context.user("Hi")])
      }

      assert {:error, _} = GenerateText.run(params, %{})
    end
  end

  describe "build_tools_from_actions/2" do
    test "converts Jido Action modules to ReqLLM Tool structs" do
      tools = GenerateText.build_tools_from_actions([TestTool], %{})

      assert length(tools) == 1
      [tool] = tools

      assert tool.name == "test_tool"
      assert tool.description == "A test tool"
    end

    test "returns empty list for empty input" do
      tools = GenerateText.build_tools_from_actions([], %{})
      assert tools == []
    end

    test "passes context to tool callback" do
      context = %{user_id: "test-user"}
      tools = GenerateText.build_tools_from_actions([TestTool], %{TestTool => context})

      [tool] = tools

      # The callback should work (we can't easily test the context is passed,
      # but we can verify the tool is callable)
      assert {:ok, _} = tool.callback.(%{query: "test"})
    end
  end
end
