defmodule Magus.Agents.Strategies.ReactStrategyTest do
  use ExUnit.Case, async: true

  alias Jido.Agent
  alias Jido.Agent.Strategy.State, as: StratState
  alias Magus.Agents.Strategies.ReactStrategy

  defmodule TestTool do
    use Jido.Action,
      name: "react_strategy_test_tool",
      description: "Tool used by ReactStrategy tests",
      schema: Zoi.object(%{value: Zoi.integer() |> Zoi.default(1)})

    @impl true
    def run(params, _context), do: {:ok, %{value: params[:value] || 1}}
  end

  defp init_agent(strategy_opts) do
    agent = %Agent{id: "react-strategy-test-agent", name: "react_strategy", state: %{}}
    ctx = %{agent_module: __MODULE__, strategy_opts: strategy_opts}
    {agent, _directives} = ReactStrategy.init(agent, ctx)
    {agent, ctx}
  end

  defp start_instruction(params) do
    %Jido.Instruction{
      action: ReactStrategy.start_action(),
      params: Map.merge(%{query: "hello", request_id: "req-test-1"}, params)
    }
  end

  defp worker_event_instruction(request_id, event) do
    %Jido.Instruction{
      action: :ai_react_worker_event,
      params: %{request_id: request_id, event: event}
    }
  end

  test "start action schema accepts per-request runtime override fields" do
    action_spec = ReactStrategy.action_spec(ReactStrategy.start_action())

    assert {:ok, _} =
             Zoi.parse(action_spec.schema, %{
               query: "hello",
               request_id: "req-test-1",
               model: "openrouter:test-model",
               max_iterations: 3,
               system_prompt: "Override prompt",
               tools: [TestTool],
               llm_opts: %{temperature: 0.9}
             })
  end

  test "honors per-request model and max_iterations without mutating base config" do
    {agent, ctx} =
      init_agent(
        tools: [TestTool],
        model: "openrouter:base-model",
        max_iterations: 10
      )

    instruction =
      start_instruction(%{
        model: "openrouter:override-model",
        max_iterations: 3
      })

    {agent, directives} = ReactStrategy.cmd(agent, [instruction], ctx)
    state = StratState.get(agent, %{})
    pending = state[:pending_worker_start]

    assert is_list(directives) and directives != []
    assert pending.config.model == "openrouter:override-model"
    assert pending.config.max_iterations == 3
    assert state.config.model == "openrouter:base-model"
    assert state.config.max_iterations == 10
  end

  test "invalid per-request max_iterations falls back to configured base value" do
    {agent, ctx} =
      init_agent(
        tools: [TestTool],
        model: "openrouter:base-model",
        max_iterations: 10
      )

    instruction = start_instruction(%{max_iterations: 0})
    {agent, _directives} = ReactStrategy.cmd(agent, [instruction], ctx)
    state = StratState.get(agent, %{})
    pending = state[:pending_worker_start]

    assert pending.config.max_iterations == 10
  end

  test "run-scoped llm_opts are applied without mutating base llm opts" do
    {agent, ctx} =
      init_agent(
        tools: [TestTool],
        model: "openrouter:base-model",
        llm_opts: [top_p: 0.5]
      )

    instruction = start_instruction(%{llm_opts: [top_p: 0.9]})
    {agent, _directives} = ReactStrategy.cmd(agent, [instruction], ctx)
    state = StratState.get(agent, %{})
    pending = state[:pending_worker_start]

    assert Keyword.get(pending.config.llm.llm_opts, :top_p) == 0.9
    assert Keyword.get(state.config.base_llm_opts, :top_p) == 0.5
  end

  test "run-scoped llm_opts cannot override tool definitions" do
    {agent, ctx} =
      init_agent(
        tools: [TestTool],
        model: "openrouter:base-model"
      )

    instruction =
      start_instruction(%{
        llm_opts: %{tools: [], temperature: 0.7}
      })

    {agent, _directives} = ReactStrategy.cmd(agent, [instruction], ctx)
    state = StratState.get(agent, %{})
    pending = state[:pending_worker_start]

    assert Map.has_key?(pending.config.tools, TestTool.name())
    refute Keyword.has_key?(pending.config.llm.llm_opts, :tools)
    assert Keyword.get(pending.config.llm.llm_opts, :temperature) == 0.7
  end

  test "run-scoped tools and system_prompt are applied for the request only" do
    {agent, ctx} =
      init_agent(
        tools: [],
        model: "openrouter:base-model",
        system_prompt: "Base prompt"
      )

    instruction =
      start_instruction(%{
        tools: [TestTool],
        system_prompt: "Request prompt"
      })

    {agent, _directives} = ReactStrategy.cmd(agent, [instruction], ctx)
    state = StratState.get(agent, %{})
    pending = state[:pending_worker_start]

    assert Map.has_key?(pending.config.tools, TestTool.name())
    assert pending.config.system_prompt == "Request prompt"
    assert [%{role: :system, content: "Request prompt"} | _] = pending.thread_messages
    assert state.config.system_prompt == "Base prompt"
    assert state.config.tools == []
  end

  test "run-scoped tools passed as map are normalized and applied" do
    {agent, ctx} =
      init_agent(
        tools: [],
        model: "openrouter:base-model"
      )

    instruction =
      start_instruction(%{
        tools: %{TestTool.name() => TestTool}
      })

    {agent, _directives} = ReactStrategy.cmd(agent, [instruction], ctx)
    state = StratState.get(agent, %{})
    pending = state[:pending_worker_start]

    assert Map.has_key?(pending.config.tools, TestTool.name())
  end

  test "tool-call turns keep assistant preamble text in streaming state and thread" do
    {agent, ctx} =
      init_agent(
        tools: [TestTool],
        model: "openrouter:base-model"
      )

    {agent, _directives} =
      ReactStrategy.cmd(agent, [start_instruction(%{})], ctx)

    llm_started =
      worker_event_instruction("req-test-1", %{
        kind: :llm_started,
        request_id: "req-test-1",
        data: %{}
      })

    llm_delta =
      worker_event_instruction("req-test-1", %{
        kind: :llm_delta,
        request_id: "req-test-1",
        llm_call_id: "call-1",
        data: %{chunk_type: :content, delta: "I'll fetch that for you."}
      })

    llm_completed =
      worker_event_instruction("req-test-1", %{
        kind: :llm_completed,
        request_id: "req-test-1",
        llm_call_id: "call-1",
        data: %{
          turn_type: :tool_calls,
          text: "I'll fetch that for you.",
          tool_calls: [%{id: "tool-1", name: TestTool.name(), arguments: %{value: 1}}],
          usage: %{}
        }
      })

    {agent, _} = ReactStrategy.cmd(agent, [llm_started], ctx)
    {agent, _} = ReactStrategy.cmd(agent, [llm_delta], ctx)
    {agent, _} = ReactStrategy.cmd(agent, [llm_completed], ctx)

    state = StratState.get(agent, %{})

    assert state[:status] == :awaiting_tool
    assert state[:streaming_text] == "I'll fetch that for you."
    assert [%{id: "tool-1"}] = state[:pending_tool_calls]

    assert %Jido.AI.Thread.Entry{
             role: :assistant,
             content: "I'll fetch that for you.",
             tool_calls: [%{id: "tool-1"}]
           } = hd(state[:run_thread].entries)
  end

  test "final-answer turns strip pseudo function_calls markup from persisted streaming text" do
    {agent, ctx} =
      init_agent(
        tools: [TestTool],
        model: "openrouter:base-model"
      )

    {agent, _directives} =
      ReactStrategy.cmd(agent, [start_instruction(%{})], ctx)

    llm_completed =
      worker_event_instruction("req-test-1", %{
        kind: :llm_completed,
        request_id: "req-test-1",
        llm_call_id: "call-2",
        data: %{
          turn_type: :final_answer,
          text:
            "I will do it. <function_calls>[{\"tool_name\":\"roll_dice\",\"arguments\":{\"notation\":\"2d10\"}}]</function_calls>\nResult is 11.",
          tool_calls: [],
          usage: %{}
        }
      })

    {agent, _} = ReactStrategy.cmd(agent, [llm_completed], ctx)
    state = StratState.get(agent, %{})

    refute String.contains?(state[:streaming_text], "<function_calls>")
    refute String.contains?(state[:streaming_text], "tool_name")
    assert String.contains?(state[:streaming_text], "Result is 11.")
  end

  test "final-answer turns strip escaped pseudo JSON tool payload from persisted streaming text" do
    {agent, ctx} =
      init_agent(
        tools: [TestTool],
        model: "openrouter:base-model"
      )

    {agent, _directives} =
      ReactStrategy.cmd(agent, [start_instruction(%{})], ctx)

    llm_completed =
      worker_event_instruction("req-test-1", %{
        kind: :llm_completed,
        request_id: "req-test-1",
        llm_call_id: "call-3",
        data: %{
          turn_type: :final_answer,
          text:
            "I'll create a draft for you.\n[{\\\"tool_name\\\":\\\"write_draft\\\",\\\"arguments\\\":{\\\"title\\\":\\\"The History\\\"}}]",
          tool_calls: [],
          usage: %{}
        }
      })

    {agent, _} = ReactStrategy.cmd(agent, [llm_completed], ctx)
    state = StratState.get(agent, %{})

    assert state[:streaming_text] == "I'll create a draft for you."
  end

  describe "usage signal emission (billing integrity)" do
    defp usage_signals(directives) do
      directives
      |> Enum.map(& &1.signal)
      |> Enum.filter(&(&1.type == "ai.usage"))
    end

    defp completed_turn(agent, ctx, usage) do
      {agent, _} = ReactStrategy.cmd(agent, [start_instruction(%{})], ctx)

      llm_completed =
        worker_event_instruction("req-test-1", %{
          kind: :llm_completed,
          request_id: "req-test-1",
          llm_call_id: "call-usage",
          data: %{
            turn_type: :final_answer,
            text: "Here is your answer.",
            tool_calls: [],
            usage: usage
          }
        })

      {_agent, directives} = ReactStrategy.cmd(agent, [llm_completed], ctx)
      directives
    end

    test "emits an ai.usage signal even when the provider returns empty usage" do
      # Regression: when streaming usage is absent (provider omitted it), the
      # turn still consumed tokens and persisted an agent message. We must still
      # emit ai.usage so a MessageUsage row is created and linked to the message
      # rather than silently dropped.
      {agent, ctx} = init_agent(tools: [TestTool], model: "openrouter:base-model")

      assert [usage_signal] = usage_signals(completed_turn(agent, ctx, %{}))
      assert usage_signal.data.model == "openrouter:base-model"
      assert usage_signal.data.input_tokens == 0
      assert usage_signal.data.output_tokens == 0
    end

    test "emits an ai.usage signal with token counts when usage is present" do
      {agent, ctx} = init_agent(tools: [TestTool], model: "openrouter:base-model")

      directives = completed_turn(agent, ctx, %{input_tokens: 100, output_tokens: 20})

      assert [usage_signal] = usage_signals(directives)
      assert usage_signal.data.input_tokens == 100
      assert usage_signal.data.output_tokens == 20
      assert usage_signal.data.total_tokens == 120
    end

    test "carries the provider generation id in the ai.usage signal metadata" do
      # The empty-usage case must still carry the generation id so usage can be
      # reconciled against OpenRouter's generation endpoint out of band.
      {agent, ctx} = init_agent(tools: [TestTool], model: "openrouter:base-model")
      {agent, _} = ReactStrategy.cmd(agent, [start_instruction(%{})], ctx)

      llm_completed =
        worker_event_instruction("req-test-1", %{
          kind: :llm_completed,
          request_id: "req-test-1",
          llm_call_id: "call-usage",
          data: %{
            turn_type: :final_answer,
            text: "Here is your answer.",
            tool_calls: [],
            usage: %{},
            generation_id: "gen-abc123"
          }
        })

      {_agent, directives} = ReactStrategy.cmd(agent, [llm_completed], ctx)

      assert [usage_signal] = usage_signals(directives)
      assert usage_signal.data.metadata.generation_id == "gen-abc123"
    end

    test "forwards provider cached tokens (prompt_tokens_details) in the metadata" do
      # Cached-read tokens are forwarded via the Usage signal metadata so the
      # context-window donut can populate last_cached_tokens. Resolution mirrors
      # Magus.Chat.MessageUsage.Changes.ExtractTokens.
      {agent, ctx} = init_agent(tools: [TestTool], model: "openrouter:base-model")

      directives =
        completed_turn(agent, ctx, %{
          input_tokens: 100,
          output_tokens: 20,
          prompt_tokens_details: %{cached_tokens: 40}
        })

      assert [usage_signal] = usage_signals(directives)
      assert usage_signal.data.metadata.cached_tokens == 40
    end

    test "forwards provider cached tokens (top-level cached_input) in the metadata" do
      {agent, ctx} = init_agent(tools: [TestTool], model: "openrouter:base-model")

      directives =
        completed_turn(agent, ctx, %{input_tokens: 100, output_tokens: 20, cached_input: 40})

      assert [usage_signal] = usage_signals(directives)
      assert usage_signal.data.metadata.cached_tokens == 40
    end

    test "defaults cached tokens to 0 when the provider omits them" do
      {agent, ctx} = init_agent(tools: [TestTool], model: "openrouter:base-model")

      directives = completed_turn(agent, ctx, %{input_tokens: 100, output_tokens: 20})

      assert [usage_signal] = usage_signals(directives)
      assert usage_signal.data.metadata.cached_tokens == 0
    end
  end

  describe "context signal emission (context-window seam)" do
    defp context_signals(directives) do
      directives
      |> Enum.filter(&match?(%Jido.Agent.Directive.Emit{}, &1))
      |> Enum.map(& &1.signal)
      |> Enum.filter(&(&1.type == "ai.context"))
    end

    test "emits exactly one ai.context signal at the start of a turn" do
      {agent, ctx} = init_agent(tools: [TestTool], model: "openrouter:base-model")

      {_agent, directives} = ReactStrategy.cmd(agent, [start_instruction(%{})], ctx)

      assert [context_signal] = context_signals(directives)

      data = context_signal.data
      assert data.model_key == "openrouter:base-model"
      # No matching Model row in this unit context -> 128k fallback.
      assert data.max_context == 128_000

      breakdown = data.breakdown
      assert is_map(breakdown)
      assert breakdown.total_tokens > 0
      assert is_list(breakdown.categories) and breakdown.categories != []

      # The TestTool schema is serialized into the tools category.
      assert Enum.any?(breakdown.categories, &(&1.key == :tools and &1.tokens > 0))
    end

    test "carries the run-scoped system prompt and resolved model in the breakdown" do
      {agent, ctx} = init_agent(tools: [TestTool], model: "openrouter:base-model")

      instruction =
        start_instruction(%{
          model: "openrouter:override-model",
          system_prompt:
            "You are a very specific override persona with a meaningfully long prompt."
        })

      {_agent, directives} = ReactStrategy.cmd(agent, [instruction], ctx)

      assert [context_signal] = context_signals(directives)
      assert context_signal.data.model_key == "openrouter:override-model"
      assert context_signal.data.breakdown.model_key == "openrouter:override-model"
      # The override prompt contributes system-prompt tokens.
      assert context_signal.data.breakdown.total_tokens > 0
    end

    test "emits one ai.context per turn (not per LLM iteration)" do
      {agent, ctx} = init_agent(tools: [TestTool], model: "openrouter:base-model")

      {agent, start_directives} = ReactStrategy.cmd(agent, [start_instruction(%{})], ctx)
      assert length(context_signals(start_directives)) == 1

      # A subsequent in-turn LLM iteration (llm_started) must NOT re-emit ai.context.
      llm_started =
        worker_event_instruction("req-test-1", %{
          kind: :llm_started,
          request_id: "req-test-1",
          llm_call_id: "call-1",
          iteration: 2
        })

      {_agent, iter_directives} = ReactStrategy.cmd(agent, [llm_started], ctx)
      assert context_signals(iter_directives) == []
    end
  end
end
