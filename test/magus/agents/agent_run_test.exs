defmodule Magus.Agents.AgentRunTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  require Ash.Query

  setup do
    user = generate(user())
    parent = generate(conversation(actor: user))
    child = generate(conversation(actor: user, is_task_conversation: true))

    %{user: user, parent: parent, child: child}
  end

  describe "create" do
    test "creates a pending run", %{parent: parent, child: child} do
      run =
        sub_agent_run(
          source_conversation_id: parent.id,
          target_conversation_id: child.id,
          objective: "Review this code"
        )

      assert run.status == :pending
      assert run.source_conversation_id == parent.id
      assert run.target_conversation_id == child.id
      assert run.objective == "Review this code"
      assert run.model_key == "openrouter:anthropic/claude-sonnet-4"
      assert run.metadata == %{}
      assert run.started_at == nil
      assert run.completed_at == nil
    end

    test "creates with custom model key and metadata", %{parent: parent} do
      run =
        sub_agent_run(
          source_conversation_id: parent.id,
          model_key: "openrouter:google/gemini-2.5-pro",
          metadata: %{agent_name: "Reviewer"}
        )

      assert run.target_agent_id == nil
      assert run.model_key == "openrouter:google/gemini-2.5-pro"
      assert run.metadata == %{"agent_name" => "Reviewer"}
    end
  end

  describe "lifecycle: start → heartbeat → complete" do
    test "transitions through full happy path", %{parent: parent, child: child} do
      run =
        sub_agent_run(
          source_conversation_id: parent.id,
          target_conversation_id: child.id
        )

      assert run.status == :pending

      # Start
      {:ok, run} = Magus.Agents.start_agent_run(run, authorize?: false)
      assert run.status == :running
      assert run.started_at != nil
      assert run.last_heartbeat_at != nil

      # Heartbeat
      {:ok, run} = Magus.Agents.heartbeat_agent_run(run, authorize?: false)
      assert run.last_heartbeat_at != nil

      # Complete
      {:ok, run} =
        Magus.Agents.complete_agent_run(run, %{result_text: "All good!"}, authorize?: false)

      assert run.status == :complete
      assert run.result_text == "All good!"
      assert run.completed_at != nil
      assert run.duration_ms != nil
      assert run.duration_ms >= 0
    end
  end

  describe "failure paths" do
    test "fail sets error status and message", %{parent: parent} do
      run = sub_agent_run(source_conversation_id: parent.id)
      {:ok, run} = Magus.Agents.start_agent_run(run, authorize?: false)

      {:ok, run} =
        Magus.Agents.fail_agent_run(
          run,
          %{error_message: "Connection reset"},
          authorize?: false
        )

      assert run.status == :error
      assert run.error_message == "Connection reset"
      assert run.completed_at != nil
    end

    test "timeout sets timed_out status", %{parent: parent} do
      run = sub_agent_run(source_conversation_id: parent.id)
      {:ok, run} = Magus.Agents.start_agent_run(run, authorize?: false)

      {:ok, run} = Magus.Agents.timeout_agent_run(run, authorize?: false)

      assert run.status == :timed_out
      assert run.completed_at != nil
    end

    test "exceed_budget sets budget_exceeded status with the wrap-up result", %{parent: parent} do
      run = sub_agent_run(source_conversation_id: parent.id)
      {:ok, run} = Magus.Agents.start_agent_run(run, authorize?: false)

      {:ok, run} =
        Magus.Agents.exceed_budget_agent_run(
          run,
          %{result_text: "Partial result before the cap"},
          authorize?: false
        )

      assert run.status == :budget_exceeded
      assert run.result_text == "Partial result before the cap"
      assert run.completed_at != nil
    end

    test "cancel sets cancelled status", %{parent: parent} do
      run = sub_agent_run(source_conversation_id: parent.id)
      {:ok, run} = Magus.Agents.start_agent_run(run, authorize?: false)

      {:ok, run} = Magus.Agents.cancel_agent_run(run, authorize?: false)

      assert run.status == :cancelled
      assert run.completed_at != nil
    end
  end

  describe "running_agent_runs/1" do
    test "returns only pending and running runs for a conversation", %{
      parent: parent,
      child: child
    } do
      # Create runs in various states
      pending_run =
        sub_agent_run(source_conversation_id: parent.id, target_conversation_id: child.id)

      running_run = sub_agent_run(source_conversation_id: parent.id)
      {:ok, running_run} = Magus.Agents.start_agent_run(running_run, authorize?: false)

      completed_run = sub_agent_run(source_conversation_id: parent.id)
      {:ok, completed_run} = Magus.Agents.start_agent_run(completed_run, authorize?: false)

      {:ok, _} =
        Magus.Agents.complete_agent_run(
          completed_run,
          %{result_text: "done"},
          authorize?: false
        )

      {:ok, active_runs} =
        Magus.Agents.running_agent_runs(parent.id, authorize?: false)

      active_ids = Enum.map(active_runs, & &1.id)
      assert pending_run.id in active_ids
      assert running_run.id in active_ids
      refute completed_run.id in active_ids
    end

    test "does not return runs from other conversations", %{parent: parent, user: user} do
      other_parent = generate(conversation(actor: user))

      _our_run = sub_agent_run(source_conversation_id: parent.id)
      _other_run = sub_agent_run(source_conversation_id: other_parent.id)

      {:ok, runs} = Magus.Agents.running_agent_runs(parent.id, authorize?: false)
      assert Enum.all?(runs, &(&1.source_conversation_id == parent.id))
    end
  end

  describe "running_agent_runs_by_target/1" do
    test "returns pending and running runs for target conversation", %{
      parent: parent,
      child: child
    } do
      run =
        sub_agent_run(
          source_conversation_id: parent.id,
          target_conversation_id: child.id
        )

      {:ok, run} = Magus.Agents.start_agent_run(run, authorize?: false)

      {:ok, runs} = Magus.Agents.running_agent_runs_by_target(child.id, authorize?: false)

      assert length(runs) == 1
      assert hd(runs).id == run.id
    end

    test "excludes completed runs", %{parent: parent, child: child} do
      run =
        sub_agent_run(
          source_conversation_id: parent.id,
          target_conversation_id: child.id
        )

      {:ok, run} = Magus.Agents.start_agent_run(run, authorize?: false)

      {:ok, _} =
        Magus.Agents.complete_agent_run(run, %{result_text: "done"}, authorize?: false)

      {:ok, runs} = Magus.Agents.running_agent_runs_by_target(child.id, authorize?: false)

      assert runs == []
    end

    test "returns results sorted by inserted_at ascending", %{parent: parent, child: child} do
      first_run =
        sub_agent_run(
          source_conversation_id: parent.id,
          target_conversation_id: child.id
        )

      Process.sleep(10)

      second_run =
        sub_agent_run(
          source_conversation_id: parent.id,
          target_conversation_id: child.id
        )

      {:ok, runs} = Magus.Agents.running_agent_runs_by_target(child.id, authorize?: false)

      run_ids = Enum.map(runs, & &1.id)
      assert run_ids == [first_run.id, second_run.id]
    end

    test "excludes runs for other target conversations", %{
      parent: parent,
      child: child,
      user: user
    } do
      other_child = generate(conversation(actor: user, is_task_conversation: true))

      _other_run =
        sub_agent_run(
          source_conversation_id: parent.id,
          target_conversation_id: other_child.id
        )

      {:ok, runs} = Magus.Agents.running_agent_runs_by_target(child.id, authorize?: false)

      assert runs == []
    end

    test "includes pending runs (not yet started)", %{parent: parent, child: child} do
      pending_run =
        sub_agent_run(
          source_conversation_id: parent.id,
          target_conversation_id: child.id
        )

      {:ok, runs} = Magus.Agents.running_agent_runs_by_target(child.id, authorize?: false)

      assert length(runs) == 1
      assert hd(runs).id == pending_run.id
      assert hd(runs).status == :pending
    end
  end

  describe "stale_runs" do
    test "finds runs that haven't heartbeated in 10+ minutes", %{parent: parent} do
      run = sub_agent_run(source_conversation_id: parent.id)
      {:ok, run} = Magus.Agents.start_agent_run(run, authorize?: false)

      # Manually set last_heartbeat_at to 3 minutes ago
      stale_time = DateTime.add(DateTime.utc_now(), -13, :minute)

      {:ok, _} =
        run
        |> Ash.Changeset.for_update(:heartbeat, %{})
        |> Ash.Changeset.force_change_attribute(:last_heartbeat_at, stale_time)
        |> Ash.update(authorize?: false)

      stale =
        Magus.Agents.AgentRun
        |> Ash.Query.for_read(:stale_runs)
        |> Ash.read!(authorize?: false)

      assert Enum.any?(stale, &(&1.id == run.id))
    end
  end

  describe "source attribute" do
    test "defaults to :mention when not set on create", %{
      user: user,
      parent: parent,
      child: child
    } do
      agent = custom_agent(user)

      {:ok, run} =
        Magus.Agents.create_agent_run(
          %{
            kind: :consult,
            source_conversation_id: parent.id,
            target_conversation_id: child.id,
            target_agent_id: agent.id,
            initiator_user_id: user.id,
            request_id: "test-#{Ash.UUID.generate()}",
            objective: "test"
          },
          authorize?: false
        )

      assert run.source == :mention
      assert run.target_agent_id == agent.id
    end

    test "accepts :heartbeat, :manual_trigger, :sub_agent_spawn", %{
      user: user,
      parent: parent,
      child: child
    } do
      agent = custom_agent(user)

      for source <- [:heartbeat, :manual_trigger, :sub_agent_spawn] do
        {:ok, run} =
          Magus.Agents.create_agent_run(
            %{
              kind: :delegate,
              source: source,
              source_conversation_id: parent.id,
              target_conversation_id: child.id,
              target_agent_id: agent.id,
              initiator_user_id: user.id,
              request_id: "test-#{Ash.UUID.generate()}",
              objective: "test"
            },
            authorize?: false
          )

        assert run.source == source
        assert run.target_agent_id == agent.id
      end
    end
  end

  describe "authorization" do
    test "outsider cannot read another user's agent run", %{
      parent: parent,
      child: child,
      user: user
    } do
      outsider = generate(user())

      run =
        sub_agent_run(
          source_conversation_id: parent.id,
          target_conversation_id: child.id,
          initiator_user_id: user.id
        )

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Magus.Agents.get_agent_run(run.id, actor: outsider)
    end

    test "user actor cannot create an agent run directly", %{user: user, parent: parent} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Magus.Agents.create_agent_run(
                 %{
                   source_conversation_id: parent.id,
                   request_id: "req-1",
                   objective: "hi"
                 },
                 actor: user
               )
    end

    test "user actor cannot cancel an agent run", %{user: user, parent: parent, child: child} do
      run =
        sub_agent_run(
          source_conversation_id: parent.id,
          target_conversation_id: child.id,
          initiator_user_id: user.id
        )

      assert {:error, %Ash.Error.Forbidden{}} =
               Magus.Agents.cancel_agent_run(run, actor: user)
    end

    test "user actor cannot destroy an agent run", %{user: user, parent: parent, child: child} do
      run =
        sub_agent_run(
          source_conversation_id: parent.id,
          target_conversation_id: child.id,
          initiator_user_id: user.id
        )

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.destroy(run, actor: user)
    end
  end
end
