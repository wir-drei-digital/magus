defmodule Magus.Agents.Tools.Tasks.AwaitSubAgentsTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Agents.Tools.Tasks.AwaitSubAgents
  alias Magus.Agents.Signals

  require Ash.Query

  defp insert_run(parent_conv_id, attrs \\ %{}) do
    base =
      %{
        kind: :subtask,
        source: :sub_agent_spawn,
        source_conversation_id: parent_conv_id,
        target_conversation_id: nil,
        objective: "x",
        model_key: "k",
        request_id: "subtask:#{Ash.UUID.generate()}",
        metadata: %{}
      }
      |> Map.merge(attrs)

    {:ok, run} = Magus.Agents.create_agent_run(base, authorize?: false)
    run
  end

  describe "schema" do
    test "has expected action name" do
      assert AwaitSubAgents.name() == "await_sub_agents"
    end
  end

  describe "display_name/0 and summarize_output/1" do
    test "display_name returns waiting message" do
      assert AwaitSubAgents.display_name() == "Waiting for sub-agents..."
    end

    test "summarize_output for completed results" do
      assert AwaitSubAgents.summarize_output(%{status: "completed", satisfied: %{completed: 2}}) ==
               "2 sub-agent(s) completed"
    end

    test "summarize_output for partial" do
      assert AwaitSubAgents.summarize_output(%{status: "partial", satisfied: %{completed: 1}}) ==
               "Returned with 1 sub-agent(s) completed"
    end

    test "summarize_output for timeout" do
      assert AwaitSubAgents.summarize_output(%{status: "timeout"}) ==
               "Timed out waiting for sub-agents"
    end

    test "summarize_output for error" do
      assert AwaitSubAgents.summarize_output(%{error: "something broke"}) ==
               "Error: something broke"
    end

    test "summarize_output fallback" do
      assert AwaitSubAgents.summarize_output(%{}) == "Done"
    end
  end

  describe "run/2 — missing context" do
    test "returns error with missing context fields" do
      {:ok, result} = AwaitSubAgents.run(%{"task_ids" => nil, "wait_for" => "all"}, %{})
      assert result.error =~ "Missing required context"
    end
  end

  describe "snapshot path (already complete on entry)" do
    test "returns immediately with status: completed" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      r1 = insert_run(conv.id)
      {:ok, r1} = Magus.Agents.start_agent_run(r1, authorize?: false)
      {:ok, _r1} = Magus.Agents.complete_agent_run(r1, %{result_text: "done"}, authorize?: false)

      assert {:ok, %{status: "completed"} = result} =
               AwaitSubAgents.run(
                 %{"task_ids" => nil, "wait_for" => "all", "timeout_seconds" => 5},
                 %{conversation_id: conv.id, user_id: user.id}
               )

      assert result.satisfied.completed == 1
    end
  end

  describe "event path" do
    test "wakes up on run.completed PubSub broadcast" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      run = insert_run(conv.id)
      {:ok, _started} = Magus.Agents.start_agent_run(run, authorize?: false)

      task =
        Task.async(fn ->
          AwaitSubAgents.run(
            %{"task_ids" => nil, "wait_for" => "all", "timeout_seconds" => 10},
            %{conversation_id: conv.id, user_id: user.id}
          )
        end)

      # Give the task a moment to subscribe
      Process.sleep(100)

      # Mark run complete in DB then broadcast
      {:ok, completed} =
        Magus.Agents.complete_agent_run(
          Ash.get!(Magus.Agents.AgentRun, run.id, authorize?: false),
          %{result_text: "ok"},
          authorize?: false
        )

      Signals.run_completed(to_string(conv.id), %{
        run_id: to_string(completed.id),
        status: "complete"
      })

      assert {:ok, %{status: "completed"}} = Task.await(task, 5_000)
    end
  end

  describe "wait_for: :first" do
    test "returns after first terminal" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      r1 = insert_run(conv.id)
      _r2 = insert_run(conv.id)

      {:ok, started} = Magus.Agents.start_agent_run(r1, authorize?: false)
      {:ok, _} = Magus.Agents.complete_agent_run(started, %{result_text: "ok"}, authorize?: false)

      assert {:ok, %{status: "completed", satisfied: %{completed: 1}}} =
               AwaitSubAgents.run(
                 %{"task_ids" => nil, "wait_for" => "first", "timeout_seconds" => 5},
                 %{conversation_id: conv.id, user_id: user.id}
               )
    end
  end

  describe "timeout" do
    test "returns status: timeout when not satisfied" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      _r1 = insert_run(conv.id)

      assert {:ok, %{status: "timeout"}} =
               AwaitSubAgents.run(
                 %{"task_ids" => nil, "wait_for" => "all", "timeout_seconds" => 1},
                 %{conversation_id: conv.id, user_id: user.id}
               )
    end

    test "handles timeout_seconds passed as string by LLM" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      _r1 = insert_run(conv.id)

      assert {:ok, %{status: "timeout"}} =
               AwaitSubAgents.run(
                 %{"task_ids" => nil, "wait_for" => "all", "timeout_seconds" => "1"},
                 %{conversation_id: conv.id, user_id: user.id}
               )
    end

    test "returns status: completed with no runs" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      assert {:ok, %{status: "completed", satisfied: %{completed: 0, total: 0}}} =
               AwaitSubAgents.run(
                 %{"task_ids" => nil, "wait_for" => "all", "timeout_seconds" => 1},
                 %{conversation_id: conv.id, user_id: user.id}
               )
    end
  end

  describe "marks delivered" do
    test "sets delivered_to_parent_at on returned terminal runs" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      r1 = insert_run(conv.id)
      {:ok, started} = Magus.Agents.start_agent_run(r1, authorize?: false)

      {:ok, completed} =
        Magus.Agents.complete_agent_run(started, %{result_text: "ok"}, authorize?: false)

      {:ok, _} =
        AwaitSubAgents.run(
          %{"task_ids" => nil, "wait_for" => "all", "timeout_seconds" => 5},
          %{conversation_id: conv.id, user_id: user.id}
        )

      refreshed = Ash.get!(Magus.Agents.AgentRun, completed.id, authorize?: false)
      refute is_nil(refreshed.delivered_to_parent_at)
    end
  end

  describe "task_ids filtering" do
    test "only returns specified task_ids, not all runs" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      r1 = insert_run(conv.id, %{objective: "Target task"})
      {:ok, r1} = Magus.Agents.start_agent_run(r1, authorize?: false)

      {:ok, r1} =
        Magus.Agents.complete_agent_run(r1, %{result_text: "target result"}, authorize?: false)

      r2 = insert_run(conv.id, %{objective: "Other task"})
      {:ok, r2} = Magus.Agents.start_agent_run(r2, authorize?: false)

      {:ok, _r2} =
        Magus.Agents.complete_agent_run(r2, %{result_text: "other result"}, authorize?: false)

      {:ok, result} =
        AwaitSubAgents.run(
          %{"task_ids" => [to_string(r1.id)], "wait_for" => "all", "timeout_seconds" => 5},
          %{conversation_id: conv.id, user_id: user.id}
        )

      assert result.status == "completed"
      assert result.satisfied.total == 1
      assert length(result.task_summaries) == 1
      assert hd(result.task_summaries).task_id == to_string(r1.id)
    end

    test "task_ids from another conversation are filtered out (completed)" do
      user = generate(user())
      conv = generate(conversation(actor: user))
      other_conv = generate(conversation(actor: user))

      r1 = insert_run(other_conv.id)
      {:ok, r1} = Magus.Agents.start_agent_run(r1, authorize?: false)
      {:ok, r1} = Magus.Agents.complete_agent_run(r1, %{result_text: "done"}, authorize?: false)

      {:ok, result} =
        AwaitSubAgents.run(
          %{"task_ids" => [to_string(r1.id)], "wait_for" => "all", "timeout_seconds" => 1},
          %{conversation_id: conv.id, user_id: user.id}
        )

      assert result.status == "completed"
      assert result.satisfied.total == 0
    end
  end

  describe "wait_for: :any" do
    test "requires min_completed_count" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      {:ok, result} =
        AwaitSubAgents.run(
          %{"task_ids" => nil, "wait_for" => "any", "timeout_seconds" => 1},
          %{conversation_id: conv.id, user_id: user.id}
        )

      assert result.error =~ "min_completed_count"
    end

    test "returns when min_completed_count satisfied" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      r1 = insert_run(conv.id)
      r2 = insert_run(conv.id)
      _r3 = insert_run(conv.id)

      {:ok, r1} = Magus.Agents.start_agent_run(r1, authorize?: false)
      {:ok, _r1} = Magus.Agents.complete_agent_run(r1, %{result_text: "a"}, authorize?: false)
      {:ok, r2} = Magus.Agents.start_agent_run(r2, authorize?: false)
      {:ok, _r2} = Magus.Agents.complete_agent_run(r2, %{result_text: "b"}, authorize?: false)

      assert {:ok, %{status: "completed", satisfied: %{completed: 2}}} =
               AwaitSubAgents.run(
                 %{
                   "task_ids" => nil,
                   "wait_for" => "any",
                   "min_completed_count" => 2,
                   "timeout_seconds" => 5
                 },
                 %{conversation_id: conv.id, user_id: user.id}
               )
    end
  end

  describe "response shape" do
    test "includes task_summaries with task_id, status, agent_name, error" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      r1 = insert_run(conv.id, %{metadata: %{"agent_name" => "MyBot"}})
      {:ok, r1} = Magus.Agents.start_agent_run(r1, authorize?: false)
      {:ok, _} = Magus.Agents.complete_agent_run(r1, %{result_text: "ok"}, authorize?: false)

      {:ok, result} =
        AwaitSubAgents.run(
          %{"task_ids" => nil, "wait_for" => "all", "timeout_seconds" => 5},
          %{conversation_id: conv.id, user_id: user.id}
        )

      assert result.status == "completed"
      assert is_list(result.task_summaries)
      assert is_binary(result.note)

      summary = hd(result.task_summaries)
      assert is_binary(summary.task_id)
      assert summary.status == "complete"
      assert summary.agent_name == "MyBot"
      assert is_nil(summary.error)
    end
  end
end
