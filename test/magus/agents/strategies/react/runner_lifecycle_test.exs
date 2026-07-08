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
