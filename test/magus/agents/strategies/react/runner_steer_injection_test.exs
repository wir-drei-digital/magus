# Test tool defined before the test module so it is compiled and loadable by the
# time Config.new validates the tool list.
#
# GateTool creates a deterministic synchronization window for the mid-turn steer.
# When the coordinator executes it (the tool round between LLM call #1 and LLM
# call #2), run/2:
#
#   1. captures the COORDINATOR pid via `$callers` (Task.async_stream tags each
#      tool task with its callers; the head is the coordinator that runs the
#      ReAct loop and whose mailbox `drain_steering!` drains),
#   2. announces itself to the test (handing over the coordinator pid),
#   3. BLOCKS until the test has injected the steer the production way AND that
#      steer has provably landed in the coordinator's mailbox as
#      `{:react_steer, ref, payload}` — the gate busy-waits on
#      `Process.info(coordinator, :messages)` until it observes the forwarded
#      steer, then returns.
#
# Returning only after the forwarded steer is in the coordinator mailbox makes
# the injection airtight: the coordinator runs `drain_steering!` (top of
# run_llm_step for call #2) strictly AFTER the tool returns, so the steer is
# guaranteed to be drained. No sleeps; the busy-wait is a real condition, not a
# timing guess.
defmodule Magus.Agents.Strategies.ReactStrategy.Runner.SteerInjectionTest.GateTool do
  @moduledoc false
  use Jido.Action,
    name: "gate_tool",
    description: "Blocks mid-turn until the steer is observed in the coordinator mailbox",
    schema: []

  def run(_params, context) do
    test_pid = context[:test_pid] || context["test_pid"]

    # The coordinator (ReAct loop process) is the first caller recorded by
    # Task.async_stream for this tool task.
    coordinator =
      case Process.get(:"$callers") do
        [coord | _] when is_pid(coord) -> coord
        _ -> nil
      end

    send(test_pid, {:gate_entered, self(), coordinator})

    # Wait for the go-ahead from the test (the test has injected the steer the
    # production way). Then busy-wait until the forwarded steer is in the
    # coordinator's mailbox before returning, so drain_steering! cannot miss it.
    receive do
      :await_steer -> :ok
    after
      10_000 -> :timeout
    end

    if is_pid(coordinator),
      do: wait_until_steer_in_mailbox(coordinator, System.monotonic_time(:millisecond))

    {:ok, %{gated: true}}
  end

  # Poll the coordinator mailbox until the forwarded steer message is present.
  # This is the airtight happens-before: the gate (a child of the coordinator)
  # does not return until {:react_steer, _, _} is enqueued for the coordinator,
  # so drain_steering! (which runs only after this tool returns) will drain it.
  #
  # Bounded so a misconfigured run fails loudly via the test's assertion (steer
  # missing from call #2) instead of hanging forever. The bound is a safety
  # backstop, NOT a timing assumption: the success path returns the instant the
  # condition holds.
  defp wait_until_steer_in_mailbox(coordinator, started_ms) do
    case Process.info(coordinator, :messages) do
      {:messages, messages} ->
        cond do
          Enum.any?(messages, &match?({:react_steer, _ref, _payload}, &1)) ->
            :ok

          System.monotonic_time(:millisecond) - started_ms > 5_000 ->
            :timeout

          true ->
            :erlang.yield()
            wait_until_steer_in_mailbox(coordinator, started_ms)
        end

      _ ->
        :ok
    end
  end
end

defmodule Magus.Agents.Strategies.ReactStrategy.Runner.SteerInjectionTest do
  @moduledoc """
  End-to-end deterministic test for the live mid-turn "send now" injection path.

  Proves that when the agent is mid-turn (it has made a tool call and is between
  tool rounds) and a steer is delivered the production way
  (`{:react_stream_steer, payload}` -> consumer `next_event` ->
  `{:react_steer, ref, payload}` -> coordinator -> `drain_steering!`), the
  steered user text reaches the NEXT LLM call's messages, appended AFTER the
  tool result.

  This exercises the seam the unit tests cannot: the live message-passing
  through the running ReAct loop. The unit tests already cover the seams in
  isolation (apply_steer_texts/drain_steering!, worker send_steer, strategy
  decide_steer, inbound build_steer_outcome); this drives a real run.

  ## The two Runner processes

    * COORDINATOR — the task spawned by `build_stream`; runs the ReAct loop. Its
      mailbox is what `drain_steering!` drains.
    * CONSUMER — the process pulling the lazy stream (here, the test process). Its
      `next_event` receives `{:react_stream_steer, _}` and forwards
      `{:react_steer, ref, _}` to the coordinator. `ref` is private to
      `next_event`, so the forward MUST go through it — this is the production
      path, not a stub.

  ## Determinism (no sleeps, no real LLM)

    1. LLM call #1 returns a tool_call for `gate_tool`.
    2. The coordinator runs `gate_tool`, which captures the coordinator pid from
       `$callers`, sends `{:gate_entered, gate_pid, coordinator}`, and blocks.
       The coordinator is now parked in the tool round, strictly BEFORE
       `drain_steering!` for call #2.
    3. The test (= consumer) injects the steer the production way:
       `send(self(), {:react_stream_steer, %{texts: [steered]}})`, then unblocks
       the gate (`:await_steer`) and pulls the next stream event. Pulling invokes
       `next_event`, which sees the queued steer and forwards
       `{:react_steer, ref, _}` to the coordinator's mailbox.
    4. The gate busy-waits on `Process.info(coordinator, :messages)` until it sees
       `{:react_steer, _, _}`, then returns. This is the airtight happens-before:
       the tool returns only after the steer is in the coordinator's mailbox.
    5. The coordinator finishes the tool round and runs `run_llm_step`. Its first
       step, `drain_steering!`, drains the queued steer and appends the steered
       user message to the thread. LLM call #2 then runs.
    6. LLM call #2's captured `messages` are asserted to contain the steered user
       message AFTER the tool result.
  """
  use ExUnit.Case, async: false

  import Mox

  alias Jido.AI.Reasoning.ReAct.Config
  alias Magus.Agents.Strategies.ReactStrategy.Runner
  alias Magus.Test.MockResponses

  setup :verify_on_exit!
  # The coordinator task (spawned by the Runner) calls the LLM mock from a
  # process the test does not own a-priori; global mode lets it through. The test
  # still verifies the exact two stream_text calls via verify_on_exit!.
  setup :set_mox_global

  setup do
    original = Application.get_env(:magus, :llm_client)
    Application.put_env(:magus, :llm_client, Magus.Test.Mocks.LLMMock)

    on_exit(fn ->
      Application.put_env(:magus, :llm_client, original || Magus.Agents.Clients.LLM)
    end)

    :ok
  end

  @steered "ACTUALLY: switch to French."

  test "a mid-turn steer reaches the next LLM call after the tool result" do
    test_pid = self()

    Magus.Test.Mocks.LLMMock
    # LLM call #1: ask for gate_tool, which puts the loop into a tool round.
    |> expect(:stream_text, fn _model, _messages, _opts ->
      MockResponses.stream_text_with_tool_call("Working...", "gate_tool", %{})
    end)
    # LLM call #2: capture the messages, then return a plain final answer.
    |> expect(:stream_text, fn _model, messages, _opts ->
      send(test_pid, {:llm_call_2_messages, messages})
      MockResponses.stream_text_response("D'accord.")
    end)

    config =
      Config.new(%{
        model: "mock:test-model",
        tools: [__MODULE__.GateTool],
        max_iterations: 5,
        streaming: true,
        tool_timeout_ms: 30_000,
        tool_concurrency: 1,
        tool_max_retries: 0,
        tool_retry_backoff_ms: 0
      })

    # The TEST process is the CONSUMER/owner: it calls Runner.stream and
    # enumerates it, so its own next_event forwards the steer to the coordinator.
    #
    # An OBSERVER process drives the handshake from the outside: the gate notifies
    # the observer (we pass the observer pid as the tool's `test_pid`), the
    # observer injects the steer into the consumer's mailbox the production way and
    # unblocks the gate. While the consumer is parked in next_event's blocking
    # receive (after consuming tool_started), the injected {:react_stream_steer, _}
    # is picked up and forwarded as {:react_steer, ref, _} to the coordinator.
    consumer = self()
    observer = spawn_link(fn -> observer(consumer) end)

    stream =
      Runner.stream("Go", config,
        request_id: "req_steer_inject",
        run_id: "run_steer_inject",
        context: %{test_pid: observer}
      )

    # Enumerate the stream in the test process (the consumer/owner). This drives
    # the whole run to completion; next_event (running here) forwards the steer.
    events = Enum.to_list(stream)

    # The run completed. LLM call #2 must have happened and captured messages.
    messages =
      receive do
        {:llm_call_2_messages, msgs} -> msgs
      after
        0 -> flunk("LLM call #2 never happened; events: #{inspect(Enum.map(events, & &1.kind))}")
      end

    assert_steer_after_tool_result!(messages)
  end

  # ---- observer ------------------------------------------------------------

  # The observer coordinates the handshake from outside the consumer. It waits
  # for the gate to enter, injects the steer the production way into the consumer
  # (the test process / `owner`), and unblocks the gate. The consumer's own
  # next_event (running as it enumerates the stream) forwards the steer to the
  # coordinator; the gate then busy-waits until that forward lands before
  # returning. See @moduledoc.
  defp observer(consumer) do
    receive do
      {:gate_entered, gate_pid, _coordinator} ->
        # Inject the steer the production way into the consumer's mailbox.
        # The consumer is currently parked in next_event's blocking receive
        # (it consumed the tool_started event and is waiting for the next one),
        # so it will pick this up and forward {:react_steer, ref, _} to the
        # coordinator.
        send(consumer, {:react_stream_steer, %{texts: [@steered]}})

        # Unblock the gate. The gate then busy-waits until the forwarded steer is
        # in the coordinator mailbox before returning, guaranteeing drain.
        send(gate_pid, :await_steer)
    after
      8_000 -> :ok
    end
  end

  # ---- assertions ----------------------------------------------------------

  defp assert_steer_after_tool_result!(messages) do
    roles_contents =
      Enum.map(messages, fn msg ->
        {Map.get(msg, :role) || Map.get(msg, "role"),
         Map.get(msg, :content) || Map.get(msg, "content")}
      end)

    tool_idx = Enum.find_index(roles_contents, fn {role, _} -> role == :tool end)

    steer_idx =
      Enum.find_index(roles_contents, fn {role, content} ->
        role == :user and is_binary(content) and content == @steered
      end)

    assert tool_idx,
           "expected a tool-result message in LLM call #2. Messages: #{inspect(roles_contents)}"

    assert steer_idx,
           "expected the steered user text #{inspect(@steered)} in LLM call #2. " <>
             "Messages: #{inspect(roles_contents)}"

    assert steer_idx > tool_idx,
           "expected the steered user message to appear AFTER the tool result. " <>
             "tool_idx=#{tool_idx} steer_idx=#{steer_idx}. Messages: #{inspect(roles_contents)}"
  end
end
