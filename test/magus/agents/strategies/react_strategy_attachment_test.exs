# Minimal agent for lifecycle tests: the ReactStrategy with no tools and no
# plugins, so a turn exercises the parent → worker → runtime-task chain
# without touching the database.
defmodule Magus.Agents.Strategies.ReactStrategyAttachmentTest.MiniAgent do
  @moduledoc false
  use Jido.Agent,
    name: "mini_react_attachment",
    strategy: {Magus.Agents.Strategies.ReactStrategy, [tools: [], streaming: true]},
    schema: []
end

defmodule Magus.Agents.Strategies.ReactStrategyAttachmentTest do
  # async: false — global Mox mode plus a named InstanceManager.
  use ExUnit.Case, async: false

  import Mox

  alias Magus.Test.MockResponses

  @manager :react_attachment_test_manager

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

  # Turn duration the mock LLM call enforces via a real sleep. BEAM sleeps
  # never return early, so this is a reliable *lower bound* on how long the
  # turn takes wall-clock, however loaded the runner is.
  @mock_llm_turn_ms 600
  @idle_timeout_ms 250

  test "an active run holds the agent alive past idle_timeout, then the timer re-arms" do
    # The turn (600ms) deliberately outlives the idle timeout (250ms). Before
    # the run-holds-attachment fix, the idle timer was blind to activity and
    # hibernated the agent mid-turn.
    stub(Magus.Test.Mocks.LLMMock, :stream_text, fn _model, _messages, _opts ->
      Process.sleep(@mock_llm_turn_ms)
      MockResponses.stream_text_response("done")
    end)

    start_supervised!(
      {Jido.Agent.InstanceManager,
       [
         name: @manager,
         agent: __MODULE__.MiniAgent,
         idle_timeout: @idle_timeout_ms,
         agent_opts: [jido: Magus.Jido, agent_module: __MODULE__.MiniAgent]
       ]}
    )

    {:ok, pid} = Jido.Agent.InstanceManager.get(@manager, "mini:attach:1")
    ref = Process.monitor(pid)

    cast_at = System.monotonic_time(:millisecond)
    signal = Jido.Signal.new!("ai.react.query", %{query: "hello", model: "mock:test-model"})
    :ok = Jido.AgentServer.cast(pid, signal)

    # Mid-turn the run's runtime task must be attached (this is what blocks
    # the idle timer) and the turn must not have failed. Poll for this
    # instead of a fixed sleep: a hardcoded wait races the agent's own
    # dispatch-to-LLM work under a loaded/slow CI runner and can observe
    # the state before the attachment lands (a known, load-dependent flake).
    #
    # Both conditions must be polled together, not just the status: the
    # parent sets `status: :awaiting_llm` on itself synchronously while
    # handling the query signal, but the runtime task that calls
    # `Jido.AgentServer.attach/2` only exists once the child worker agent
    # and its Task actually get scheduled — a separate, later step.
    {server_state, strategy_state} =
      wait_until(fn ->
        state = :sys.get_state(pid)
        strategy_state = state.agent.state[:__strategy__] || %{}

        if strategy_state[:status] == :awaiting_llm and
             MapSet.size(state.lifecycle.attachments) == 1 do
          {:ok, {state, strategy_state}}
        else
          :error
        end
      end)

    assert MapSet.size(server_state.lifecycle.attachments) == 1
    assert strategy_state[:status] == :awaiting_llm

    # The agent must survive the whole turn even though it crosses the idle
    # timeout. The mock LLM call can't return before @mock_llm_turn_ms has
    # elapsed since `cast_at` (a real Process.sleep never returns early), so
    # refuting for whatever's left of that window (minus a safety margin)
    # stays valid no matter how long the poll above took.
    elapsed_ms = System.monotonic_time(:millisecond) - cast_at
    refute_window_ms = max(50, @mock_llm_turn_ms - elapsed_ms - 100)
    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, refute_window_ms

    # After the turn completes the attachment drops and the idle timer
    # re-arms: the agent must still hibernate when genuinely idle. Generous
    # timeout for slow runners — this only slows the test down if it were
    # going to fail anyway.
    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :idle_timeout}}, 5_000
  end

  # Polls `fun` (which returns `{:ok, value}` or `:error`) until it succeeds
  # or `timeout` elapses, instead of a fixed `Process.sleep` that races real
  # work under a loaded/slow CI runner. `fun` may hit `:sys.get_state/1` on a
  # process that hasn't finished booting yet (raises `:exit`) under heavy
  # scheduler contention — that's treated as just another `:error` to retry,
  # not a hard crash, so the test fails with a clear "timed out" message
  # instead of a raw `:sys.get_state` stacktrace if the condition is never
  # met by the deadline.
  # 15s is generous on purpose: observed under a fully-loaded local `mix test`
  # run (thousands of concurrent tests contending for schedulers and the DB
  # pool) that 5s was occasionally not enough for this low-priority agent's
  # setup + first dispatch to get scheduled. A passing run returns as soon as
  # the condition is met, so this only costs time when something is already
  # wrong.
  defp wait_until(fun, timeout \\ 15_000, interval \\ 10) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline, interval)
  end

  defp do_wait_until(fun, deadline, interval) do
    case safe_poll(fun) do
      {:ok, value} ->
        value

      :error ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("condition not met within the polling timeout")
        else
          Process.sleep(interval)
          do_wait_until(fun, deadline, interval)
        end
    end
  end

  defp safe_poll(fun) do
    fun.()
  catch
    :exit, _ -> :error
  end
end
