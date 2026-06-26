defmodule Magus.LiveE2E.SubAgentResumeTest do
  @moduledoc """
  E2E test for the orphan sub-agent auto-resume flow.

  Verifies Section 3 of the "Robust Sub-Agent Spawn / Await" spec:
  - Parent spawns 2 sub-agents without awaiting them
  - Parent responds immediately and goes idle
  - Sub-agents complete their runs
  - SubAgentResumer detects the orphaned spawns and wakes parent via `agent.resume`
  - InboundPlugin transforms the resume into `ai.react.query`
  - Parent runs a second turn (second `response.complete` arrives)
  - Each spawn tool message has its `tool_call_data.output["status"]`
    updated from "spawning" to "complete"/"error"/"timed_out"
  """
  use Magus.LiveE2ECase, async: false

  require Ash.Query

  @moduletag :sub_agent_resume
  @moduletag timeout: 240_000

  describe "auto-resume after orphaned spawn" do
    test "parent's spawn tool messages have terminal output and parent runs an extra turn", %{
      user: user,
      model: model
    } do
      conversation = create_conversation(user, model)
      subscribe_to_agent(conversation.id)

      send_user_message(
        conversation,
        user,
        """
        Spawn 2 quick sub-agents, each tasked with replying with a single
        sentence. Do NOT call await_sub_agents — just respond saying you
        kicked off the work.
        """
      )

      # Wait for the parent's first turn (with the spawns) to complete.
      assert_response_complete(60_000)

      # Drain any trailing signals from the first turn so they don't
      # interfere with the second-turn assertion below.
      drain_signals(500)

      # Now wait for the parent to wake up via SubAgentResumer once both
      # children finish. The resumer fires an `agent.resume` signal which
      # InboundPlugin converts to a fresh `ai.react.query` turn.
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "agent_signal",
                       payload: %{type: "response.complete"}
                     },
                     120_000,
                     "Expected second response.complete (auto-resume turn) within 120s"

      # Verify spawn tool messages have terminal output baked in.
      events =
        Magus.Chat.Message
        |> Ash.Query.filter(
          conversation_id == ^conversation.id and
            message_type == :event
        )
        |> Ash.read!(authorize?: false)
        |> Enum.filter(fn msg ->
          get_in(msg.tool_call_data, ["tool_name"]) == "spawn_sub_agent"
        end)

      assert length(events) >= 2,
             "Expected at least 2 spawn_sub_agent tool event messages, got #{length(events)}"

      Enum.each(events, fn ev ->
        output = ev.tool_call_data["output"] || ev.tool_call_data[:output] || %{}

        assert output["status"] in ["complete", "error", "timed_out"],
               "spawn tool output status was #{inspect(output["status"])}, expected a terminal status"

        if output["status"] == "complete" do
          assert is_binary(output["result_text"]),
                 "Expected result_text to be a string, got #{inspect(output["result_text"])}"
        end
      end)
    end
  end
end
