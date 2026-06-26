defmodule Magus.LiveE2E.SubAgentTest do
  @moduledoc """
  E2E test for the sub-agent spawn → await lifecycle.

  Verifies the full pipeline: parent LLM calls spawn_sub_agent, child agent
  runs to completion, child tool events relay as steps on the parent card,
  parent calls await_sub_agents to collect the result, and responds.
  """
  use Magus.LiveE2ECase, async: false

  @moduletag :sub_agent
  @moduletag timeout: 300_000

  describe "sub-agent lifecycle" do
    test "spawn, relay child steps, await, and respond", %{user: user, model: model} do
      conversation = create_conversation(user, model)
      subscribe_to_agent(conversation.id)

      send_user_message(
        conversation,
        user,
        """
        Use the spawn_sub_agent tool to delegate a task. The objective should be:
        "Use the set_memory tool to remember that the project mascot is a penguin
        (key 'mascot', value 'penguin'), then report what you stored."

        After spawning, use await_sub_agents with the task_id to wait for the result.
        Then tell me what the sub-agent stored.
        """
      )

      # 1. Parent calls spawn_sub_agent
      _spawn_payload = assert_tool_started("spawn_sub_agent", 60_000)
      assert_tool_completed("spawn_sub_agent", 30_000)

      # 2. Parent calls await_sub_agents to collect the result
      assert_tool_started("await_sub_agents", 120_000)
      assert_tool_completed("await_sub_agents", 120_000)

      # 3. Parent provides final response
      assert_response_complete(60_000)

      # 4. Collect remaining signals and verify
      all_signals = collect_all_signals(500)
      signal_types = Enum.map(all_signals, & &1.payload[:type])

      # Debug: check for run failures
      run_failed =
        Enum.find(all_signals, fn s -> s.payload[:type] == "run.failed" end)

      if run_failed do
        flunk(
          "Child run FAILED: #{inspect(Map.take(run_failed.payload, [:error, :status, :kind, :objective, :run_id, :source_event_id]))}"
        )
      end

      # Child relay steps should have arrived (tool.step.start/complete)
      has_relay =
        Enum.any?(signal_types, fn t -> t in ["tool.step.start", "tool.step.complete"] end)

      assert has_relay,
             "Expected child relay events (tool.step.*), got signal types: #{inspect(Enum.uniq(signal_types))}"
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp collect_all_signals(timeout) do
    collect_acc([], timeout)
  end

  defp collect_acc(acc, timeout) do
    receive do
      %Phoenix.Socket.Broadcast{event: "agent_signal"} = broadcast ->
        collect_acc([broadcast | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end
end
