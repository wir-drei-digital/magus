defmodule Magus.Agents.Integration.FanOutTest do
  @moduledoc """
  Integration test for the fan-out/collect pattern.

  Validates the full lifecycle: parent spawns sub-agents via SpawnSubAgent,
  each returns a deferred result with a task_id, sub-agent runs are completed
  via domain functions, and AwaitSubAgents collects the results.
  """

  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Agents.Tools.Tasks.{SpawnSubAgent, AwaitSubAgents, ReportToParent}

  @moduletag :integration

  setup do
    user = generate(user())
    conversation = generate(conversation(actor: user))
    # Reload user to ensure all fields are populated
    user = Ash.load!(user, [], authorize?: false)

    context = %{
      conversation_id: conversation.id,
      user_id: user.id,
      user: user
    }

    %{user: user, conversation: conversation, context: context}
  end

  describe "fan-out/collect pattern" do
    test "spawn sub-agents, complete them, and collect all results", %{
      context: context,
      conversation: parent
    } do
      # 1. Spawn two sub-agents via the SpawnSubAgent tool
      {:ok, result1} =
        SpawnSubAgent.run(
          %{"objective" => "Research topic A", "system_prompt" => "You are a researcher."},
          context
        )

      {:ok, result2} =
        SpawnSubAgent.run(
          %{"objective" => "Research topic B", "system_prompt" => "You are a researcher."},
          context
        )

      # 2. Verify result shape
      assert result1.status == "spawning"
      assert is_binary(result1.task_id)
      assert is_binary(result1.target_conversation_id)

      assert result2.status == "spawning"
      assert is_binary(result2.task_id)
      assert is_binary(result2.target_conversation_id)

      # Task IDs should be distinct
      refute result1.task_id == result2.task_id

      # 3. Verify AgentRun records exist in pending state
      {:ok, run1} = Magus.Agents.get_agent_run(result1.task_id, authorize?: false)
      {:ok, run2} = Magus.Agents.get_agent_run(result2.task_id, authorize?: false)

      assert run1.status == :pending
      assert run1.source_conversation_id == parent.id
      assert run1.objective == "Research topic A"

      assert run2.status == :pending
      assert run2.source_conversation_id == parent.id
      assert run2.objective == "Research topic B"

      # 4. Simulate sub-agent execution: start then complete each run
      {:ok, run1} = Magus.Agents.start_agent_run(run1, authorize?: false)
      assert run1.status == :running

      {:ok, run1} =
        Magus.Agents.complete_agent_run(
          run1,
          %{result_text: "Topic A findings: XYZ"},
          authorize?: false
        )

      assert run1.status == :complete

      {:ok, run2} = Magus.Agents.start_agent_run(run2, authorize?: false)

      {:ok, run2} =
        Magus.Agents.complete_agent_run(
          run2,
          %{result_text: "Topic B findings: ABC"},
          authorize?: false
        )

      assert run2.status == :complete

      # 5. Await both results via AwaitSubAgents
      {:ok, collected} =
        AwaitSubAgents.run(
          %{
            "task_ids" => [result1.task_id, result2.task_id],
            "wait_for" => "all"
          },
          context
        )

      assert collected.status == "completed"
      assert collected.satisfied.completed == 2
      assert length(collected.task_summaries) == 2

      # Verify each summary contains the expected task_id and status
      summaries_by_task = Map.new(collected.task_summaries, &{&1.task_id, &1})

      assert summaries_by_task[result1.task_id].status == "complete"
      assert summaries_by_task[result2.task_id].status == "complete"

      # Verify the underlying AgentRun records have the expected data
      {:ok, final_run1} = Magus.Agents.get_agent_run(result1.task_id, authorize?: false)
      {:ok, final_run2} = Magus.Agents.get_agent_run(result2.task_id, authorize?: false)
      assert final_run1.result_text == "Topic A findings: XYZ"
      assert final_run2.result_text == "Topic B findings: ABC"
    end

    test "await returns results with mixed completion order", %{
      context: context
    } do
      # Spawn two sub-agents
      {:ok, result1} =
        SpawnSubAgent.run(
          %{"objective" => "Fast task", "system_prompt" => "Be quick."},
          context
        )

      {:ok, result2} =
        SpawnSubAgent.run(
          %{"objective" => "Slow task", "system_prompt" => "Be thorough."},
          context
        )

      # Complete first task
      {:ok, run1} = Magus.Agents.get_agent_run(result1.task_id, authorize?: false)
      {:ok, run1} = Magus.Agents.start_agent_run(run1, authorize?: false)

      {:ok, _run1} =
        Magus.Agents.complete_agent_run(
          run1,
          %{result_text: "Quick result"},
          authorize?: false
        )

      # Complete second task
      {:ok, run2} = Magus.Agents.get_agent_run(result2.task_id, authorize?: false)
      {:ok, run2} = Magus.Agents.start_agent_run(run2, authorize?: false)

      {:ok, _run2} =
        Magus.Agents.complete_agent_run(
          run2,
          %{result_text: "Thorough result"},
          authorize?: false
        )

      # Await collects both results
      {:ok, collected} =
        AwaitSubAgents.run(%{}, context)

      assert collected.status == "completed"
      assert collected.satisfied.completed == 2
      assert length(collected.task_summaries) == 2

      summaries_by_task = Map.new(collected.task_summaries, &{&1.task_id, &1})
      assert summaries_by_task[result1.task_id].status == "complete"
      assert summaries_by_task[result2.task_id].status == "complete"

      # Verify the underlying AgentRun records have the expected data
      {:ok, final_run1} = Magus.Agents.get_agent_run(result1.task_id, authorize?: false)
      {:ok, final_run2} = Magus.Agents.get_agent_run(result2.task_id, authorize?: false)
      assert final_run1.result_text == "Quick result"
      assert final_run2.result_text == "Thorough result"
    end

    test "handles mixed success and failure results", %{
      context: context
    } do
      # Spawn two sub-agents
      {:ok, result1} =
        SpawnSubAgent.run(
          %{"objective" => "Succeed task", "system_prompt" => "Do your best."},
          context
        )

      {:ok, result2} =
        SpawnSubAgent.run(
          %{"objective" => "Fail task", "system_prompt" => "Try hard."},
          context
        )

      # Complete first successfully
      {:ok, run1} = Magus.Agents.get_agent_run(result1.task_id, authorize?: false)
      {:ok, run1} = Magus.Agents.start_agent_run(run1, authorize?: false)

      {:ok, _run1} =
        Magus.Agents.complete_agent_run(
          run1,
          %{result_text: "Success!"},
          authorize?: false
        )

      # Fail the second
      {:ok, run2} = Magus.Agents.get_agent_run(result2.task_id, authorize?: false)
      {:ok, run2} = Magus.Agents.start_agent_run(run2, authorize?: false)

      {:ok, _run2} =
        Magus.Agents.fail_agent_run(
          run2,
          %{error_message: "Something went wrong"},
          authorize?: false
        )

      # Await all — both are terminal states so it should return
      {:ok, collected} =
        AwaitSubAgents.run(
          %{
            "task_ids" => [result1.task_id, result2.task_id],
            "wait_for" => "all",
            "timeout_seconds" => 10
          },
          context
        )

      assert collected.status == "completed"
      assert collected.satisfied.completed == 2
      assert length(collected.task_summaries) == 2

      summaries_by_task = Map.new(collected.task_summaries, &{&1.task_id, &1})

      assert summaries_by_task[result1.task_id].status == "complete"
      assert summaries_by_task[result2.task_id].status == "error"
      assert summaries_by_task[result2.task_id].error == "Something went wrong"
    end

    test "respects concurrency limit across spawned sub-agents", %{
      context: context,
      conversation: parent
    } do
      # Pre-create 3 running sub-agent runs to hit the concurrency limit
      for _i <- 1..3 do
        run = sub_agent_run(source_conversation_id: parent.id)
        Magus.Agents.start_agent_run(run, authorize?: false)
      end

      # Attempting to spawn a 4th should fail with concurrency error
      {:ok, result} =
        SpawnSubAgent.run(
          %{"objective" => "This should be rejected", "system_prompt" => "Test."},
          context
        )

      assert result.error =~ "Maximum"
    end

    test "ReportToParent broadcasts progress to parent conversation", %{
      context: context,
      conversation: parent
    } do
      # 1. Spawn a sub-agent to create a child conversation with a running run
      {:ok, spawn_result} =
        SpawnSubAgent.run(
          %{"objective" => "Long research task", "system_prompt" => "You are a researcher."},
          context
        )

      assert spawn_result.status == "spawning"
      target_conversation_id = spawn_result.target_conversation_id

      # Start the run so it's in :running state (required for ReportToParent lookup)
      {:ok, run} = Magus.Agents.get_agent_run(spawn_result.task_id, authorize?: false)
      {:ok, _run} = Magus.Agents.start_agent_run(run, authorize?: false)

      # 2. Subscribe to parent's PubSub topic for broadcasts
      parent_topic = "agents:#{parent.id}"
      MagusWeb.Endpoint.subscribe(parent_topic)

      # 3. Call ReportToParent from the child's context
      child_context = %{
        conversation_id: target_conversation_id
      }

      {:ok, report_result} =
        ReportToParent.run(
          %{"status" => "Found 3 relevant papers so far", "progress_percent" => 40},
          child_context
        )

      assert report_result.reported == true
      assert report_result.status == "Found 3 relevant papers so far"

      # 4. Verify PubSub broadcast was received on the parent's channel
      assert_receive %Phoenix.Socket.Broadcast{
        topic: ^parent_topic,
        event: "agent_signal",
        payload: %{
          type: "tool.progress",
          tool_name: "sub_agent",
          progress_type: :progress_report,
          data: %{
            status: "Found 3 relevant papers so far",
            progress_percent: 40
          }
        }
      }
    end

    test "spawn_sub_agent stores source_event_id on AgentRun", %{
      context: context
    } do
      # Add __event_id__ to context (simulates ReAct worker enrichment)
      event_id = Ash.UUIDv7.generate()
      context_with_event = Map.put(context, :__event_id__, event_id)

      {:ok, result} =
        SpawnSubAgent.run(
          %{"objective" => "Test event relay", "system_prompt" => "You are a tester."},
          context_with_event
        )

      assert result.status == "spawning"

      # Verify the AgentRun has source_event_id set
      {:ok, run} = Magus.Agents.get_agent_run(result.task_id, authorize?: false)
      assert run.source_event_id != nil
    end

    test "ReportToParent returns error when not running as a sub-agent", %{
      context: context
    } do
      # Call ReportToParent with the parent conversation context (no AgentRun exists)
      {:ok, result} =
        ReportToParent.run(
          %{"status" => "Should fail"},
          %{conversation_id: context.conversation_id}
        )

      assert result.error == "Not running as a sub-agent task"
    end
  end
end
