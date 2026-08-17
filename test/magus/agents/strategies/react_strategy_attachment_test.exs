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

  # The turn itself is mocked away from the DB, but the agent's early turn
  # path can incidentally query (e.g. a cold cache falling back to Postgres).
  # Without a sandbox owner that checkout dies with :noproc and takes the
  # agent down mid-test (observed intermittently on CI). Shared mode lets any
  # process in the agent's tree query safely.
  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Magus.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  setup do
    original = Application.get_env(:magus, :llm_client)
    Application.put_env(:magus, :llm_client, Magus.Test.Mocks.LLMMock)

    on_exit(fn ->
      Application.put_env(:magus, :llm_client, original || Magus.Agents.Clients.LLM)
    end)

    :ok
  end

  # Generous on purpose. The span between casting the query and the runtime
  # task's `attach/2` call is real scheduling work; if the idle timer fires
  # inside that span, the agent hibernates before the run can hold it open —
  # observed under synthetic 16-burner starvation with a 250ms window. In
  # production the idle timeout is minutes, so the cast-to-attach span can
  # never plausibly cross it; the test window must preserve that ratio on a
  # starved 2-core CI runner rather than shrink it to the point where the
  # test manufactures a race production cannot hit.
  @idle_timeout_ms 1_500

  test "an active run holds the agent alive past idle_timeout, then the timer re-arms" do
    # The turn deliberately outlives the idle timeout. Before the
    # run-holds-attachment fix, the idle timer was blind to activity and
    # hibernated the agent mid-turn.
    #
    # The mock turn is HELD OPEN until this test releases it, instead of a
    # fixed-duration sleep: a fixed turn length gives the mid-turn state a
    # fixed observable window, and a starved CI scheduler can miss that
    # window entirely (the turn completes before the first poll lands),
    # after which no polling budget helps — the state never comes back.
    # Holding the turn makes the mid-turn observation deterministic.
    test_pid = self()

    stub(Magus.Test.Mocks.LLMMock, :stream_text, fn _model, _messages, _opts ->
      send(test_pid, {:llm_call_started, self()})

      receive do
        :finish_turn -> :ok
      after
        # Safety valve: a failing test must not hang the suite.
        30_000 -> :ok
      end

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

    signal = Jido.Signal.new!("ai.react.query", %{query: "hello", model: "mock:test-model"})
    :ok = Jido.AgentServer.cast(pid, signal)

    # The turn is provably in flight once the mock LLM call reports in, and
    # it stays in flight until we send :finish_turn.
    assert_receive {:llm_call_started, llm_pid}, 15_000

    # Mid-turn the run's runtime task must be attached (this is what blocks
    # the idle timer) and the turn must not have failed. Poll for this
    # rather than asserting immediately: `attach/2` happens in the runtime
    # task around the LLM call, so its ordering relative to our mailbox
    # message is not guaranteed — but with the turn held open the state
    # persists, so the poll converges deterministically.
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

    # The agent must survive past the idle timeout while the turn is still
    # running — and it IS still running, because we haven't released the
    # mock. One full idle window plus a fire margin leaves no doubt the
    # timer had its chance.
    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, @idle_timeout_ms + 1_000

    # Release the turn. After it completes the attachment drops and the
    # idle timer re-arms: the agent must still hibernate when genuinely
    # idle. Generous timeout for slow runners — a passing run returns as
    # soon as the DOWN arrives.
    send(llm_pid, :finish_turn)
    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :idle_timeout}}, 15_000
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
