# Test tool modules must be defined before the test module so they're
# compiled and loaded by the time Config.new validates them.

# A tool that hangs far longer than any configured timeout.
defmodule Magus.Agents.Strategies.ReactStrategy.RunnerLifecycleTest.HangingTool do
  @moduledoc false
  use Jido.Action,
    name: "hanging_tool",
    description: "Sleeps far past the tool timeout",
    schema: []

  def run(_params, _context) do
    Process.sleep(5_000)
    {:ok, %{finished: true}}
  end
end

# An instant tool for budget tests.
defmodule Magus.Agents.Strategies.ReactStrategy.RunnerLifecycleTest.QuickTool do
  @moduledoc false
  use Jido.Action,
    name: "quick_tool",
    description: "Completes instantly",
    schema: []

  def run(_params, _context), do: {:ok, %{done: true}}
end

# A deliberately slow tool that declares its own execution timeout, overriding
# the run-level tool_timeout_ms.
defmodule Magus.Agents.Strategies.ReactStrategy.RunnerLifecycleTest.SlowToolWithOverride do
  @moduledoc false
  use Jido.Action,
    name: "slow_tool_with_override",
    description: "Slow but declares a longer per-tool timeout",
    schema: []

  def execution_timeout_ms, do: 5_000

  def run(_params, _context) do
    Process.sleep(400)
    {:ok, %{finished: true}}
  end
end

defmodule Magus.Agents.Strategies.ReactStrategy.RunnerLifecycleTest do
  # async: false — uses global Mox mode so stubs are reachable from the
  # coordinator/consumer processes spawned outside the test process.
  use ExUnit.Case, async: false

  import Mox

  alias Jido.AI.Reasoning.ReAct.Config
  alias Magus.Agents.Strategies.ReactStrategy.Runner
  alias Magus.Test.MockResponses

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    original = Application.get_env(:magus, :llm_client)
    Application.put_env(:magus, :llm_client, Magus.Test.Mocks.LLMMock)

    on_exit(fn ->
      Application.put_env(:magus, :llm_client, original || Magus.Agents.Clients.LLM)
    end)

    :ok
  end

  describe "tool timeout enforcement" do
    test "a hanging tool is killed at tool_timeout_ms and reports a timeout error" do
      Magus.Test.Mocks.LLMMock
      |> expect(:stream_text, fn _model, _messages, _opts ->
        MockResponses.stream_text_with_tool_call("Running...", "hanging_tool", %{})
      end)
      |> expect(:stream_text, fn _model, _messages, _opts ->
        MockResponses.stream_text_response("Recovered from the timeout.")
      end)

      config =
        Config.new(%{
          model: "mock:test-model",
          tools: [__MODULE__.HangingTool],
          max_iterations: 5,
          streaming: true,
          tool_timeout_ms: 150,
          tool_max_retries: 0,
          tool_retry_backoff_ms: 0
        })

      started_at = System.monotonic_time(:millisecond)

      events =
        Runner.stream("Do it", config, request_id: "req_to1", run_id: "run_to1")
        |> Enum.to_list()

      elapsed = System.monotonic_time(:millisecond) - started_at

      completed =
        Enum.find(events, &(&1.kind == :tool_completed and &1.data.tool_name == "hanging_tool"))

      assert {:error, %{type: :timeout}} = completed.data.result
      assert Enum.any?(events, &(&1.kind == :request_completed))

      # The turn must not have waited out the tool's 5s sleep.
      assert elapsed < 3_000,
             "expected the hanging tool to be cut off at ~150ms, but the turn took #{elapsed}ms"
    end

    test "a tool exporting execution_timeout_ms/0 overrides the run-level timeout" do
      Magus.Test.Mocks.LLMMock
      |> expect(:stream_text, fn _model, _messages, _opts ->
        MockResponses.stream_text_with_tool_call("Running...", "slow_tool_with_override", %{})
      end)
      |> expect(:stream_text, fn _model, _messages, _opts ->
        MockResponses.stream_text_response("Done")
      end)

      config =
        Config.new(%{
          model: "mock:test-model",
          tools: [__MODULE__.SlowToolWithOverride],
          max_iterations: 5,
          streaming: true,
          tool_timeout_ms: 100,
          tool_max_retries: 0,
          tool_retry_backoff_ms: 0
        })

      events =
        Runner.stream("Do it", config, request_id: "req_to2", run_id: "run_to2")
        |> Enum.to_list()

      completed =
        Enum.find(
          events,
          &(&1.kind == :tool_completed and &1.data.tool_name == "slow_tool_with_override")
        )

      assert {:ok, %{finished: true}} = completed.data.result
    end
  end

  describe "checkpoint emission" do
    test "checkpoint events are not emitted by default (nothing consumes them)" do
      Magus.Test.Mocks.LLMMock
      |> expect(:stream_text, fn _model, _messages, _opts ->
        MockResponses.stream_text_response("done")
      end)

      config =
        Config.new(%{model: "mock:test-model", tools: [], max_iterations: 5, streaming: true})

      events =
        Runner.stream("q", config, request_id: "req_chk_off", run_id: "run_chk_off")
        |> Enum.to_list()

      refute Enum.any?(events, &(&1.kind == :checkpoint))
      assert Enum.any?(events, &(&1.kind == :request_completed))
    end

    test "checkpoint events are emitted when :emit_checkpoints is enabled" do
      original = Application.get_env(:magus, :agents, [])
      Application.put_env(:magus, :agents, Keyword.put(original, :emit_checkpoints, true))
      on_exit(fn -> Application.put_env(:magus, :agents, original) end)

      Magus.Test.Mocks.LLMMock
      |> expect(:stream_text, fn _model, _messages, _opts ->
        MockResponses.stream_text_response("done")
      end)

      config =
        Config.new(%{model: "mock:test-model", tools: [], max_iterations: 5, streaming: true})

      events =
        Runner.stream("q", config, request_id: "req_chk_on", run_id: "run_chk_on")
        |> Enum.to_list()

      assert Enum.any?(events, &(&1.kind == :checkpoint))
    end
  end

  describe "turn keepalive" do
    test "broadcasts turn.keepalive while the turn runs and stops when it ends" do
      conversation_id = Ecto.UUID.generate()

      original = Application.get_env(:magus, :agents, [])
      Application.put_env(:magus, :agents, Keyword.put(original, :turn_keepalive_interval_ms, 50))
      on_exit(fn -> Application.put_env(:magus, :agents, original) end)

      stub(Magus.Test.Mocks.LLMMock, :stream_text, fn _model, _messages, _opts ->
        Process.sleep(300)
        MockResponses.stream_text_response("done")
      end)

      MagusWeb.Endpoint.subscribe("agents:#{conversation_id}")

      config =
        Config.new(%{
          model: "mock:test-model",
          tools: [],
          max_iterations: 5,
          streaming: true
        })

      events =
        Runner.stream("q", config,
          request_id: "req_ka1",
          run_id: "run_ka1",
          context: %{conversation_id: conversation_id}
        )
        |> Enum.to_list()

      assert Enum.any?(events, &(&1.kind == :request_completed))

      # At least one keepalive must have been broadcast during the 300ms turn.
      # The same tick also touches RunLiveness, so the broadcast doubles as
      # evidence the liveness touch ran.
      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "turn.keepalive"}
      }

      # The ticker must die with the turn. A tick in flight at coordinator
      # exit may still land (link teardown is async), so let stragglers
      # settle, drain, then expect silence for several intervals.
      Process.sleep(100)
      drain_keepalives()
      refute_receive %Phoenix.Socket.Broadcast{payload: %{type: "turn.keepalive"}}, 200
    end

    defp drain_keepalives do
      receive do
        %Phoenix.Socket.Broadcast{payload: %{type: "turn.keepalive"}} -> drain_keepalives()
      after
        0 -> :ok
      end
    end
  end

  describe "token budget wrap-up" do
    test "an over-budget run gets one tool-less wrap-up call and completes as budget_exceeded" do
      Magus.Test.Mocks.LLMMock
      |> expect(:stream_text, fn _model, _messages, _opts ->
        # Blows straight through the 100-token cap.
        MockResponses.stream_text_with_tool_call("Working...", "quick_tool", %{},
          output_tokens: 500
        )
      end)
      |> expect(:stream_text, fn _model, messages, opts ->
        # The wrap-up call must not offer tools and must carry the wrap-up
        # instruction as the trailing user message.
        assert Keyword.get(opts, :tools, []) == []

        assert Enum.any?(messages, fn msg ->
                 content = msg[:content] || msg["content"]
                 is_binary(content) and content =~ "budget"
               end)

        MockResponses.stream_text_response("Best answer with what I have")
      end)

      config =
        Config.new(%{
          model: "mock:test-model",
          tools: [__MODULE__.QuickTool],
          max_iterations: 10,
          streaming: true
        })

      events =
        Runner.stream("Do a big task", config,
          request_id: "req_budget1",
          run_id: "run_budget1",
          context: %{max_tokens_per_run: 100}
        )
        |> Enum.to_list()

      # The already-requested tool round still runs (thread consistency),
      # then the budget trips before the next planning step.
      assert Enum.any?(events, &(&1.kind == :tool_completed))

      completed = Enum.find(events, &(&1.kind == :request_completed))
      assert completed.data.termination_reason == :budget_exceeded
      assert completed.data.max_tokens_per_run == 100
      assert completed.data.result == "Best answer with what I have"
    end

    test "runs without a cap never emit budget events" do
      Magus.Test.Mocks.LLMMock
      |> expect(:stream_text, fn _model, _messages, _opts ->
        MockResponses.stream_text_response("done", output_tokens: 500_000)
      end)

      config =
        Config.new(%{
          model: "mock:test-model",
          tools: [],
          max_iterations: 5,
          streaming: true
        })

      events =
        Runner.stream("q", config, request_id: "req_budget2", run_id: "run_budget2")
        |> Enum.to_list()

      completed = Enum.find(events, &(&1.kind == :request_completed))
      assert completed.data.termination_reason == :final_answer
    end
  end

  describe "transient LLM error retry" do
    setup do
      original = Application.get_env(:magus, :agents, [])

      Application.put_env(
        :magus,
        :agents,
        Keyword.merge(original, llm_transient_max_retries: 2, llm_transient_retry_backoff_ms: 1)
      )

      on_exit(fn -> Application.put_env(:magus, :agents, original) end)
      :ok
    end

    test "a transient provider error is retried and the turn completes" do
      Magus.Test.Mocks.LLMMock
      |> expect(:stream_text, fn _model, _messages, _opts ->
        {:error, %{status: 429, message: "rate limited"}}
      end)
      |> expect(:stream_text, fn _model, _messages, _opts ->
        MockResponses.stream_text_response("recovered")
      end)

      config =
        Config.new(%{
          model: "mock:test-model",
          tools: [],
          max_iterations: 5,
          streaming: true
        })

      events =
        Runner.stream("q", config, request_id: "req_retry1", run_id: "run_retry1")
        |> Enum.to_list()

      completed = Enum.find(events, &(&1.kind == :request_completed))
      assert completed, "expected the turn to complete after a retry"
      assert completed.data.result == "recovered"
    end

    test "a non-retryable provider error fails the turn immediately" do
      Magus.Test.Mocks.LLMMock
      |> expect(:stream_text, fn _model, _messages, _opts ->
        {:error, %{error: %{message: "invalid api key", type: "auth_error"}}}
      end)

      config =
        Config.new(%{
          model: "mock:test-model",
          tools: [],
          max_iterations: 5,
          streaming: true
        })

      events =
        Runner.stream("q", config, request_id: "req_retry2", run_id: "run_retry2")
        |> Enum.to_list()

      assert Enum.any?(events, &(&1.kind == :request_failed))
      refute Enum.any?(events, &(&1.kind == :request_completed))
    end
  end

  describe "max_iterations wrap-up" do
    test "hitting the iteration limit produces a real final answer, not a canned string" do
      Magus.Test.Mocks.LLMMock
      |> expect(:stream_text, fn _model, _messages, _opts ->
        MockResponses.stream_text_with_tool_call("Working...", "quick_tool", %{})
      end)
      |> expect(:stream_text, fn _model, messages, opts ->
        # Wrap-up call: no tools, with an iteration-limit instruction.
        assert Keyword.get(opts, :tools, []) == []

        assert Enum.any?(messages, fn msg ->
                 content = msg[:content] || msg["content"]
                 is_binary(content) and content =~ "iteration limit"
               end)

        MockResponses.stream_text_response("Here is where I got before the limit")
      end)

      config =
        Config.new(%{
          model: "mock:test-model",
          tools: [__MODULE__.QuickTool],
          max_iterations: 1,
          streaming: true
        })

      events =
        Runner.stream("Big task", config, request_id: "req_iter1", run_id: "run_iter1")
        |> Enum.to_list()

      completed = Enum.find(events, &(&1.kind == :request_completed))
      assert completed.data.termination_reason == :max_iterations
      assert completed.data.result == "Here is where I got before the limit"
    end
  end

  describe "cancellation during a tool round" do
    test "cancel kills the in-flight tool instead of waiting it out" do
      test_pid = self()

      stub(Magus.Test.Mocks.LLMMock, :stream_text, fn _model, _messages, _opts ->
        MockResponses.stream_text_with_tool_call("Running...", "hanging_tool", %{})
      end)

      config =
        Config.new(%{
          model: "mock:test-model",
          tools: [__MODULE__.HangingTool],
          max_iterations: 5,
          streaming: true,
          # Far above the tool's 5s sleep: only cancellation can end it early.
          tool_timeout_ms: 30_000,
          tool_max_retries: 0,
          tool_retry_backoff_ms: 0
        })

      consumer =
        Task.async(fn ->
          Runner.stream("q", config, request_id: "req_cancel1", run_id: "run_cancel1")
          |> Enum.map(fn event ->
            send(test_pid, {:ev, event.kind})
            event
          end)
        end)

      assert_receive {:ev, :tool_started}, 2_000

      send(consumer.pid, {:react_stream_cancel, :user_cancelled})

      # The 5s hanging tool must not be waited out.
      result = Task.yield(consumer, 2_000)
      assert result != nil, "cancellation did not interrupt the in-flight tool round"

      {:ok, events} = result
      assert Enum.any?(events, &(&1.kind == :request_cancelled))
    end
  end

  describe "runner chain teardown" do
    test "killing the stream consumer kills the coordinator task" do
      stub(Magus.Test.Mocks.LLMMock, :stream_text, fn _model, _messages, _opts ->
        Process.sleep(:infinity)
      end)

      {:ok, sup} = Task.Supervisor.start_link()

      config =
        Config.new(%{
          model: "mock:test-model",
          tools: [],
          max_iterations: 5,
          streaming: true
        })

      consumer =
        spawn(fn ->
          Runner.stream("q", config,
            request_id: "req_link1",
            run_id: "run_link1",
            task_supervisor: sup
          )
          |> Stream.run()
        end)

      assert eventually(fn -> Task.Supervisor.children(sup) != [] end),
             "coordinator task never started under the supervisor"

      Process.exit(consumer, :kill)

      assert eventually(fn -> Task.Supervisor.children(sup) == [] end),
             "coordinator task survived its consumer's death"
    end

    test "halt_on_down halts the stream and kills the coordinator when the watched pid dies" do
      stub(Magus.Test.Mocks.LLMMock, :stream_text, fn _model, _messages, _opts ->
        Process.sleep(:infinity)
      end)

      {:ok, sup} = Task.Supervisor.start_link()
      victim = spawn(fn -> Process.sleep(:infinity) end)

      config =
        Config.new(%{
          model: "mock:test-model",
          tools: [],
          max_iterations: 5,
          streaming: true
        })

      consumer =
        Task.async(fn ->
          Runner.stream("q", config,
            request_id: "req_halt1",
            run_id: "run_halt1",
            task_supervisor: sup,
            halt_on_down: victim
          )
          |> Enum.to_list()
        end)

      assert eventually(fn -> Task.Supervisor.children(sup) != [] end),
             "coordinator task never started under the supervisor"

      Process.exit(victim, :kill)

      assert Task.yield(consumer, 1_500) != nil,
             "stream did not halt after the watched pid died"

      assert eventually(fn -> Task.Supervisor.children(sup) == [] end),
             "coordinator task survived after halt_on_down fired"

      Task.shutdown(consumer, :brutal_kill)
    end
  end

  defp eventually(fun, attempts \\ 40)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
  end
end
