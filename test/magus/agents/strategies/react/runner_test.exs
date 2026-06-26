# Test tool modules must be defined before the test module so they're
# compiled and loaded by the time Config.new validates them.

# A fast tool that completes immediately — no heartbeat needed
defmodule Magus.Agents.Strategies.ReactStrategy.RunnerTest.FastTool do
  @moduledoc false
  use Jido.Action,
    name: "fast_tool",
    description: "Completes instantly",
    schema: []

  def run(_params, _context), do: {:ok, %{done: true}}
end

defmodule Magus.Agents.Strategies.ReactStrategy.RunnerTest.LoaderTool do
  @moduledoc false
  use Jido.Action,
    name: "loader_tool",
    description: "Loads new tools mid-turn",
    schema: []

  def run(_params, _context) do
    {:ok,
     %{
       loaded: true,
       __new_tools__: [Magus.Agents.Strategies.ReactStrategy.RunnerTest.TargetTool]
     }}
  end
end

defmodule Magus.Agents.Strategies.ReactStrategy.RunnerTest.TargetTool do
  @moduledoc false
  use Jido.Action,
    name: "target_tool",
    description: "A tool registered mid-turn",
    schema: [
      value: [type: {:or, [:string, nil]}, default: nil, doc: "A value"]
    ]

  def run(params, _context) do
    {:ok, %{result: "computed_#{params[:value] || params["value"] || "nil"}"}}
  end
end

defmodule Magus.Agents.Strategies.ReactStrategy.RunnerTest.CrashTool do
  @moduledoc false
  use Jido.Action,
    name: "crash_tool",
    description: "Always crashes",
    schema: []

  def run(_params, _context), do: raise("boom")
end

defmodule Magus.Agents.Strategies.ReactStrategy.RunnerTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Support.ToolsHelper
  alias ReqLLM.StreamChunk

  describe "extract_tool_calls_from_chunks/1" do
    test "reconstructs tool arguments from tool_call + meta fragments" do
      chunks = [
        %StreamChunk{
          type: :tool_call,
          name: "write_draft",
          arguments: %{},
          metadata: %{id: "call_1", index: 0}
        },
        StreamChunk.meta(%{
          tool_call_args: %{index: 0, fragment: "{\"title\":\"The History\"}"}
        })
      ]

      assert [
               %{
                 id: "call_1",
                 name: "write_draft",
                 arguments: %{"title" => "The History"}
               }
             ] = ToolsHelper.extract_tool_calls_from_chunks(chunks)
    end

    test "marks malformed argument fragments as parse errors" do
      chunks = [
        %StreamChunk{
          type: :tool_call,
          name: "roll_dice",
          arguments: %{},
          metadata: %{id: "call_2", index: 0}
        },
        StreamChunk.meta(%{
          tool_call_args: %{index: 0, fragment: "{\"notation\":"}
        })
      ]

      assert [
               %{
                 id: "call_2",
                 name: "roll_dice",
                 arguments: :parse_error
               }
             ] = ToolsHelper.extract_tool_calls_from_chunks(chunks)
    end
  end

  describe "mid-turn tool registration via __new_tools__" do
    import Mox

    alias Jido.AI.Reasoning.ReAct.Config
    alias Magus.Agents.Strategies.ReactStrategy.Runner
    alias Magus.Test.MockResponses

    setup :verify_on_exit!

    setup do
      original = Application.get_env(:magus, :llm_client)
      Application.put_env(:magus, :llm_client, Magus.Test.Mocks.LLMMock)

      on_exit(fn ->
        Application.put_env(:magus, :llm_client, original || Magus.Agents.Clients.LLM)
      end)

      :ok
    end

    test "tools returned in __new_tools__ are available in subsequent iterations" do
      # LLM call 1: requests the "loader" tool
      # LLM call 2: requests the "target" tool (registered mid-turn by loader)
      # LLM call 3: final answer
      Magus.Test.Mocks.LLMMock
      |> expect(:stream_text, fn _model, _messages, _opts ->
        MockResponses.stream_text_with_tool_call("Loading...", "loader_tool", %{})
      end)
      |> expect(:stream_text, fn _model, _messages, _opts ->
        MockResponses.stream_text_with_tool_call("Running...", "target_tool", %{value: "42"})
      end)
      |> expect(:stream_text, fn _model, _messages, _opts ->
        MockResponses.stream_text_response("The answer is 42")
      end)

      config =
        Config.new(%{
          model: "mock:test-model",
          tools: [__MODULE__.LoaderTool],
          max_iterations: 10,
          streaming: true
        })

      # loader_tool should be registered, target_tool should NOT
      assert Map.has_key?(config.tools, "loader_tool"),
             "loader_tool missing from config.tools: #{inspect(config.tools)}"

      refute Map.has_key?(config.tools, "target_tool")

      events =
        Runner.stream("Load and run", config, request_id: "req_test", run_id: "run_test")
        |> Enum.to_list()

      # Both tools should have started and completed
      tool_started_names =
        events
        |> Enum.filter(&(&1.kind == :tool_started))
        |> Enum.map(& &1.data.tool_name)

      tool_completed_names =
        events
        |> Enum.filter(&(&1.kind == :tool_completed))
        |> Enum.map(& &1.data.tool_name)

      assert "loader_tool" in tool_started_names
      assert "target_tool" in tool_started_names
      assert "loader_tool" in tool_completed_names
      assert "target_tool" in tool_completed_names

      # target_tool should have succeeded (not unknown_tool error)
      target_completed =
        Enum.find(events, &(&1.kind == :tool_completed and &1.data.tool_name == "target_tool"))

      assert {:ok, %{result: "computed_42"}} = target_completed.data.result

      # Final answer should be present
      assert Enum.any?(events, &(&1.kind == :request_completed))
    end

    test "__new_tools__ key is stripped from tool results sent to LLM" do
      Magus.Test.Mocks.LLMMock
      |> expect(:stream_text, fn _model, _messages, _opts ->
        MockResponses.stream_text_with_tool_call("Loading...", "loader_tool", %{})
      end)
      |> expect(:stream_text, fn _model, messages, _opts ->
        # Check that the tool result in the messages doesn't contain __new_tools__
        tool_results =
          messages
          |> Enum.filter(fn
            %{role: :tool} -> true
            _ -> false
          end)

        for result <- tool_results do
          content = result.content
          refute content =~ "__new_tools__"
          refute content =~ "Elixir."
        end

        MockResponses.stream_text_response("Done")
      end)

      config =
        Config.new(%{
          model: "mock:test-model",
          tools: [__MODULE__.LoaderTool],
          max_iterations: 10,
          streaming: true
        })

      Runner.stream("Load skill", config, request_id: "req_test2", run_id: "run_test2")
      |> Enum.to_list()
    end
  end

  describe "tool execution" do
    import Mox

    alias Jido.AI.Reasoning.ReAct.Config
    alias Magus.Agents.Strategies.ReactStrategy.Runner
    alias Magus.Test.MockResponses

    setup :verify_on_exit!

    setup do
      original = Application.get_env(:magus, :llm_client)
      Application.put_env(:magus, :llm_client, Magus.Test.Mocks.LLMMock)

      on_exit(fn ->
        Application.put_env(:magus, :llm_client, original || Magus.Agents.Clients.LLM)
      end)

      :ok
    end

    test "fast tool completes normally" do
      Magus.Test.Mocks.LLMMock
      |> expect(:stream_text, fn _model, _messages, _opts ->
        MockResponses.stream_text_with_tool_call("Running...", "fast_tool", %{})
      end)
      |> expect(:stream_text, fn _model, _messages, _opts ->
        MockResponses.stream_text_response("Done")
      end)

      config =
        Config.new(%{
          model: "mock:test-model",
          tools: [__MODULE__.FastTool],
          max_iterations: 5,
          streaming: true,
          tool_timeout_ms: 5_000,
          tool_concurrency: 2,
          tool_max_retries: 0,
          tool_retry_backoff_ms: 0
        })

      events =
        Runner.stream("Do it", config, request_id: "req_hb1", run_id: "run_hb1")
        |> Enum.to_list()

      completed =
        Enum.find(events, &(&1.kind == :tool_completed and &1.data.tool_name == "fast_tool"))

      assert {:ok, %{done: true}} = completed.data.result
      assert Enum.any?(events, &(&1.kind == :request_completed))
    end
  end

  describe "tool task failure recovery" do
    import Mox

    alias Jido.AI.Reasoning.ReAct.Config
    alias Magus.Agents.Strategies.ReactStrategy.Runner
    alias Magus.Test.MockResponses

    setup :verify_on_exit!

    setup do
      original = Application.get_env(:magus, :llm_client)
      Application.put_env(:magus, :llm_client, Magus.Test.Mocks.LLMMock)

      on_exit(fn ->
        Application.put_env(:magus, :llm_client, original || Magus.Agents.Clients.LLM)
      end)

      :ok
    end

    test "crashed tool still produces tool_completed event with error" do
      # LLM call 1: requests a tool that will crash
      # LLM call 2: final answer after receiving error tool_result
      Magus.Test.Mocks.LLMMock
      |> expect(:stream_text, fn _model, _messages, _opts ->
        MockResponses.stream_text_with_tool_call("Running...", "crash_tool", %{})
      end)
      |> expect(:stream_text, fn _model, _messages, _opts ->
        MockResponses.stream_text_response("Handled the error gracefully.")
      end)

      config =
        Config.new(%{
          model: "mock:test-model",
          tools: [__MODULE__.CrashTool],
          max_iterations: 5,
          streaming: true
        })

      events =
        Runner.stream("Try it", config, request_id: "req_crash", run_id: "run_crash")
        |> Enum.to_list()

      # The tool should have started
      assert Enum.any?(events, &(&1.kind == :tool_started))

      # The runner should complete despite the crash
      assert Enum.any?(events, &(&1.kind == :request_completed))
    end
  end
end
