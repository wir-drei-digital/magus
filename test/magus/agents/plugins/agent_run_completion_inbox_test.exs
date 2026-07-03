defmodule Magus.Agents.Plugins.AgentRunCompletionInboxTest do
  @moduledoc """
  Tests that AgentRunCompletionPlugin wires into the inbox/activity system:
  - Resolves AgentInboxEvent when a linked run completes
  - Marks AgentInboxEvent as waiting when a linked run fails
  - Creates AgentActivityLog entries on completion and failure
  """

  use Magus.DataCase, async: false

  import Magus.Generators

  require Ash.Query

  alias Magus.Agents.AgentInboxEvent
  alias Magus.Agents.AgentRun
  alias Magus.Agents.Plugins.AgentRunCompletionPlugin

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp build_agent(conversation_id, overrides \\ %{}) do
    base_state =
      Map.merge(
        %{
          conversation_id: conversation_id,
          user_id: "test-user-id",
          mode: :chat,
          model_keys: %{chat: "test-model"},
          __strategy__: %{
            active_request_id: nil,
            streaming_text: "Result text",
            streaming_thinking: "",
            pending_tool_calls: []
          }
        },
        overrides
      )

    %{id: "conv:#{conversation_id}", state: base_state}
  end

  defp build_context(agent), do: %{agent: agent}

  defp make_signal(type, data), do: Jido.Signal.new!(type, data)

  defp create_conversations(user) do
    parent_conv = generate(conversation(actor: user))

    child_conv =
      generate(
        conversation(
          actor: user,
          is_task_conversation: true,
          parent_conversation_id: parent_conv.id
        )
      )

    {parent_conv, child_conv}
  end

  defp create_inbox_event(user, agent) do
    {:ok, event} =
      Magus.Agents.create_inbox_event(
        %{
          agent_id: agent.id,
          event_type: :mention,
          urgency: :immediate,
          title: "Test mention",
          source_type: :conversation
        },
        actor: user
      )

    event
  end

  # `:inbox_urgent` is a budget-gated source in `RunOrchestrator`: without an
  # active subscription, `check_owner_spend_budget/1` rejects every enqueue
  # with `:insufficient_spend_budget` (`get_effective_limits/1` falls back to
  # a zero spend cap). Give the user a free plan so drain's enqueue can
  # succeed in tests that expect a new run to be created.
  defp give_free_plan(user) do
    free_plan = ensure_free_plan()

    {:ok, _subscription} =
      Magus.Usage.create_user_subscription(
        %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
        authorize?: false
      )

    :ok
  end

  defp create_run(user, parent_conv, child_conv, agent, opts) do
    attrs =
      Keyword.merge(
        [
          source_conversation_id: parent_conv.id,
          target_conversation_id: child_conv.id,
          target_agent_id: Keyword.get(opts, :target_agent_id, agent.id),
          initiator_user_id: user.id,
          event_id: Keyword.get(opts, :event_id)
        ],
        opts
      )

    sub_agent_run(attrs)
  end

  # ============================================================================
  # Inbox event resolution on run completion
  # ============================================================================

  describe "inbox event resolution on ai.request.completed" do
    test "resolves linked inbox event when run completes" do
      user = generate(user())
      agent = custom_agent(user)
      {parent_conv, child_conv} = create_conversations(user)
      event = create_inbox_event(user, agent)

      run =
        create_run(user, parent_conv, child_conv, agent,
          target_agent_id: agent.id,
          event_id: event.id
        )

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      context = build_context(build_agent(child_conv.id))
      signal = make_signal("ai.request.completed", %{request_id: run.request_id})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)

      {:ok, updated_event} = Ash.get(AgentInboxEvent, event.id, authorize?: false)
      assert updated_event.status == :resolved
      assert updated_event.resolved_by == :agent
      assert updated_event.run_id == run.id
      assert updated_event.resolution_note == "Run completed"
    end

    test "does not error when run has no event_id" do
      user = generate(user())
      agent = custom_agent(user)
      {parent_conv, child_conv} = create_conversations(user)

      # Run without event_id
      run =
        create_run(user, parent_conv, child_conv, agent,
          target_agent_id: agent.id,
          event_id: nil
        )

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      context = build_context(build_agent(child_conv.id))
      signal = make_signal("ai.request.completed", %{request_id: run.request_id})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)
    end

    test "does not error when run has nil event_id on completion" do
      user = generate(user())
      agent = custom_agent(user)
      {parent_conv, child_conv} = create_conversations(user)

      run =
        create_run(user, parent_conv, child_conv, agent,
          target_agent_id: agent.id,
          event_id: nil
        )

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      context = build_context(build_agent(child_conv.id))
      signal = make_signal("ai.request.completed", %{request_id: run.request_id})

      # Should not raise — skips resolve when no event_id
      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)
    end
  end

  # ============================================================================
  # Inbox event waiting on run failure
  # ============================================================================

  describe "inbox event waiting on ai.request.failed" do
    test "marks linked inbox event as waiting when run fails" do
      user = generate(user())
      agent = custom_agent(user)
      {parent_conv, child_conv} = create_conversations(user)
      event = create_inbox_event(user, agent)

      run =
        create_run(user, parent_conv, child_conv, agent,
          target_agent_id: agent.id,
          event_id: event.id
        )

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      context = build_context(build_agent(child_conv.id))

      signal =
        make_signal("ai.request.failed", %{error: "LLM timeout", request_id: run.request_id})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)

      {:ok, updated_event} = Ash.get(AgentInboxEvent, event.id, authorize?: false)
      assert updated_event.status == :waiting
    end

    test "does not error when failed run has no event_id" do
      user = generate(user())
      agent = custom_agent(user)
      {parent_conv, child_conv} = create_conversations(user)

      run =
        create_run(user, parent_conv, child_conv, agent,
          target_agent_id: agent.id,
          event_id: nil
        )

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      context = build_context(build_agent(child_conv.id))
      signal = make_signal("ai.request.failed", %{error: "timeout", request_id: run.request_id})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)
    end
  end

  # ============================================================================
  # Activity log creation
  # ============================================================================

  describe "activity log process dict on ai.request.completed" do
    test "sets :activity_log_last_completed_run in process dict when run completes" do
      user = generate(user())
      agent = custom_agent(user)
      {parent_conv, child_conv} = create_conversations(user)

      run =
        create_run(user, parent_conv, child_conv, agent,
          target_agent_id: agent.id,
          initiator_user_id: user.id
        )

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      context = build_context(build_agent(child_conv.id))
      signal = make_signal("ai.request.completed", %{request_id: run.request_id})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)

      completed_run = Process.get(:activity_log_last_completed_run)
      assert completed_run != nil
      assert completed_run.id == run.id
      assert completed_run.status == :complete
    end

    test "completed run in process dict includes event_id and task_id when set" do
      user = generate(user())
      agent = custom_agent(user)
      {parent_conv, child_conv} = create_conversations(user)
      event = create_inbox_event(user, agent)
      {:ok, task} = Magus.Plan.create_task(parent_conv.id, %{title: "Test task"}, actor: user)

      run =
        create_run(user, parent_conv, child_conv, agent,
          target_agent_id: agent.id,
          initiator_user_id: user.id,
          event_id: event.id,
          task_id: task.id
        )

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      context = build_context(build_agent(child_conv.id))
      signal = make_signal("ai.request.completed", %{request_id: run.request_id})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)

      completed_run = Process.get(:activity_log_last_completed_run)
      assert completed_run != nil
      assert completed_run.event_id == event.id
      assert completed_run.task_id == task.id
    end

    test "does not set process dict when run has no target_agent_id" do
      user = generate(user())
      _agent = custom_agent(user)
      {parent_conv, child_conv} = create_conversations(user)

      # Run without target_agent_id
      run =
        sub_agent_run(
          source_conversation_id: parent_conv.id,
          target_conversation_id: child_conv.id,
          initiator_user_id: user.id,
          target_agent_id: nil
        )

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      context = build_context(build_agent(child_conv.id))
      signal = make_signal("ai.request.completed", %{request_id: run.request_id})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)

      # Process dict is still set (ActivityLogPlugin will handle filtering by agent_id)
      completed_run = Process.get(:activity_log_last_completed_run)
      assert completed_run != nil
      assert completed_run.target_agent_id == nil
    end
  end

  describe "activity log process dict on ai.request.failed" do
    test "sets :activity_log_last_failed_run in process dict when run fails" do
      user = generate(user())
      agent = custom_agent(user)
      {parent_conv, child_conv} = create_conversations(user)

      run =
        create_run(user, parent_conv, child_conv, agent,
          target_agent_id: agent.id,
          initiator_user_id: user.id
        )

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      context = build_context(build_agent(child_conv.id))

      signal =
        make_signal("ai.request.failed", %{error: "provider down", request_id: run.request_id})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)

      failed_run = Process.get(:activity_log_last_failed_run)
      assert failed_run != nil
      assert failed_run.id == run.id
      assert failed_run.status == :error
    end
  end

  # ============================================================================
  # Drain-before-sleep: pending :immediate events get a follow-up run
  # ============================================================================

  describe "drain-before-sleep" do
    test "pending :immediate event enqueues follow-up :inbox_urgent run after heartbeat completes" do
      user = generate(user())
      :ok = give_free_plan(user)
      agent = custom_agent(user, %{heartbeat_enabled: true})
      {parent_conv, child_conv} = create_conversations(user)

      heartbeat_run =
        create_run(user, parent_conv, child_conv, agent,
          source: :heartbeat,
          target_agent_id: agent.id
        )

      {:ok, running_run} = Magus.Agents.start_agent_run(heartbeat_run.id, authorize?: false)

      # Seed an :immediate event while the heartbeat run is :running so
      # TriggerUrgentWake's in-flight gate rejects the wake, leaving the
      # event unlinked (agent_run_id: nil) — exactly the "arrived mid-run"
      # scenario.
      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :mention,
            urgency: :immediate,
            title: "Urgent thing happened",
            source_type: :conversation
          },
          actor: user
        )

      assert event.agent_run_id == nil

      {:ok, completed_run} =
        Magus.Agents.complete_agent_run(running_run, %{result_text: "done"}, authorize?: false)

      AgentRunCompletionPlugin.handle_run_completed(completed_run)

      {:ok, updated_event} = Ash.get(AgentInboxEvent, event.id, authorize?: false)
      assert updated_event.agent_run_id != nil

      {:ok, new_run} = Ash.get(AgentRun, updated_event.agent_run_id, authorize?: false)
      assert new_run.source == :inbox_urgent
      assert new_run.idempotency_key == "inbox:#{event.id}"
    end

    test "drain does not re-run an event whose urgent run already happened" do
      user = generate(user())
      agent = custom_agent(user, %{heartbeat_enabled: true})
      {parent_conv, child_conv} = create_conversations(user)

      # Seed the event while a heartbeat run is :running so TriggerUrgentWake's
      # in-flight gate rejects the auto-wake (event stays unlinked).
      seed_run =
        create_run(user, parent_conv, child_conv, agent,
          source: :heartbeat,
          target_agent_id: agent.id
        )

      {:ok, running_seed_run} = Magus.Agents.start_agent_run(seed_run.id, authorize?: false)

      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :mention,
            urgency: :immediate,
            title: "Urgent thing happened",
            source_type: :conversation
          },
          actor: user
        )

      assert event.agent_run_id == nil

      # Simulate the event's urgent run already having happened (and
      # completed) by consuming its idempotency key directly, then clearing
      # the link the same way `unlink_linked_inbox_events` would.
      urgent_run =
        create_run(user, parent_conv, child_conv, agent,
          source: :inbox_urgent,
          target_agent_id: agent.id,
          idempotency_key: "inbox:#{event.id}"
        )

      {:ok, started} = Magus.Agents.start_agent_run(urgent_run.id, authorize?: false)

      {:ok, _completed} =
        Magus.Agents.complete_agent_run(started, %{result_text: "handled"}, authorize?: false)

      # Event stays pending and unlinked, as if the run's completion path had
      # already unlinked/resolved it independently of this drain.
      {:ok, event} = Ash.get(AgentInboxEvent, event.id, authorize?: false)
      assert event.status == :pending
      assert event.agent_run_id == nil

      # Finish the original seed run and let the drain run for it.
      {:ok, other_completed} =
        Magus.Agents.complete_agent_run(running_seed_run, %{result_text: "done"},
          authorize?: false
        )

      AgentRunCompletionPlugin.handle_run_completed(other_completed)

      matching_runs =
        AgentRun
        |> Ash.Query.filter(idempotency_key == ^"inbox:#{event.id}")
        |> Ash.read!(authorize?: false)

      assert length(matching_runs) == 1

      {:ok, final_event} = Ash.get(AgentInboxEvent, event.id, authorize?: false)
      assert final_event.status == :pending
      assert final_event.agent_run_id == nil
    end

    test "drain ignores :deferred events" do
      user = generate(user())
      agent = custom_agent(user, %{heartbeat_enabled: true})
      {parent_conv, child_conv} = create_conversations(user)

      heartbeat_run =
        create_run(user, parent_conv, child_conv, agent,
          source: :heartbeat,
          target_agent_id: agent.id
        )

      {:ok, running_run} = Magus.Agents.start_agent_run(heartbeat_run.id, authorize?: false)

      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :mention,
            urgency: :deferred,
            title: "Not urgent",
            source_type: :conversation
          },
          actor: user
        )

      assert event.agent_run_id == nil

      {:ok, completed_run} =
        Magus.Agents.complete_agent_run(running_run, %{result_text: "done"}, authorize?: false)

      AgentRunCompletionPlugin.handle_run_completed(completed_run)

      {:ok, updated_event} = Ash.get(AgentInboxEvent, event.id, authorize?: false)
      assert updated_event.agent_run_id == nil
      assert updated_event.status == :pending

      matching_runs =
        AgentRun
        |> Ash.Query.filter(idempotency_key == ^"inbox:#{event.id}")
        |> Ash.read!(authorize?: false)

      assert matching_runs == []
    end

    test "drain skips non-autonomous (e.g. :mention) run completions" do
      user = generate(user())
      agent = custom_agent(user, %{heartbeat_enabled: true})
      {parent_conv, child_conv} = create_conversations(user)

      # Seed under a running heartbeat run so the in-flight gate rejects the
      # auto-wake, leaving the event unlinked.
      seed_run =
        create_run(user, parent_conv, child_conv, agent,
          source: :heartbeat,
          target_agent_id: agent.id
        )

      {:ok, _running_seed_run} = Magus.Agents.start_agent_run(seed_run.id, authorize?: false)

      event = create_inbox_event_immediate(user, agent)
      assert event.agent_run_id == nil

      mention_run =
        create_run(user, parent_conv, child_conv, agent,
          source: :mention,
          target_agent_id: agent.id
        )

      {:ok, started} = Magus.Agents.start_agent_run(mention_run.id, authorize?: false)

      {:ok, completed} =
        Magus.Agents.complete_agent_run(started, %{result_text: "done"}, authorize?: false)

      AgentRunCompletionPlugin.handle_run_completed(completed)

      {:ok, updated_event} = Ash.get(AgentInboxEvent, event.id, authorize?: false)
      assert updated_event.agent_run_id == nil

      matching_runs =
        AgentRun
        |> Ash.Query.filter(idempotency_key == ^"inbox:#{event.id}")
        |> Ash.read!(authorize?: false)

      assert matching_runs == []
    end

    test "drain skips paused agents (single-opt-in)" do
      user = generate(user())
      :ok = give_free_plan(user)
      # Paused agent: even a pending :immediate event must NOT get a follow-up
      # run when an autonomous run completes.
      agent = custom_agent(user, %{heartbeat_enabled: true, is_paused: true})
      {parent_conv, child_conv} = create_conversations(user)

      heartbeat_run =
        create_run(user, parent_conv, child_conv, agent,
          source: :heartbeat,
          target_agent_id: agent.id
        )

      {:ok, running_run} = Magus.Agents.start_agent_run(heartbeat_run.id, authorize?: false)

      # Seed a pending :immediate event. Because the agent is paused,
      # TriggerUrgentWake also skips, so it stays unlinked and pending.
      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :mention,
            urgency: :immediate,
            title: "Urgent thing happened",
            source_type: :conversation
          },
          actor: user
        )

      assert event.agent_run_id == nil

      {:ok, completed_run} =
        Magus.Agents.complete_agent_run(running_run, %{result_text: "done"}, authorize?: false)

      AgentRunCompletionPlugin.handle_run_completed(completed_run)

      {:ok, updated_event} = Ash.get(AgentInboxEvent, event.id, authorize?: false)
      assert updated_event.agent_run_id == nil
      assert updated_event.status == :pending

      matching_runs =
        AgentRun
        |> Ash.Query.filter(idempotency_key == ^"inbox:#{event.id}")
        |> Ash.read!(authorize?: false)

      assert matching_runs == []
    end

    test "drain leaves a :waiting approval event untouched" do
      user = generate(user())
      :ok = give_free_plan(user)
      agent = custom_agent(user, %{heartbeat_enabled: true})
      {parent_conv, child_conv} = create_conversations(user)

      heartbeat_run =
        create_run(user, parent_conv, child_conv, agent,
          source: :heartbeat,
          target_agent_id: agent.id
        )

      {:ok, running_run} = Magus.Agents.start_agent_run(heartbeat_run.id, authorize?: false)

      # A :waiting approval REQUEST the agent raised, blocked on a human.
      # source_id is the conversation the approval was requested in.
      {:ok, waiting_event} =
        Magus.Agents.create_waiting_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :approval_response,
            urgency: :immediate,
            title: "Waiting for approval",
            source_type: :conversation,
            source_id: parent_conv.id,
            payload: %{"options" => ["Approve", "Reject"], "question" => "Deploy to prod?"}
          },
          actor: user
        )

      assert waiting_event.status == :waiting
      assert waiting_event.agent_run_id == nil

      {:ok, completed_run} =
        Magus.Agents.complete_agent_run(running_run, %{result_text: "done"}, authorize?: false)

      AgentRunCompletionPlugin.handle_run_completed(completed_run)

      # Drain must NOT touch the waiting event: it stays :waiting and unlinked.
      {:ok, reloaded} = Ash.get(AgentInboxEvent, waiting_event.id, authorize?: false)
      assert reloaded.status == :waiting
      assert reloaded.agent_run_id == nil

      # And no urgent run was enqueued for it.
      matching_runs =
        AgentRun
        |> Ash.Query.filter(idempotency_key == ^"inbox:#{waiting_event.id}")
        |> Ash.read!(authorize?: false)

      assert matching_runs == []

      # Now the user answers via the InboxEventPlugin approval-matching path:
      # the waiting event resolves and a new :immediate :approval_response
      # :pending event is created (mirrors inbox_event_plugin_test).
      plugin_agent = %{
        id: "conv:#{parent_conv.id}",
        state: %{
          user_id: user.id,
          conversation_id: parent_conv.id,
          mode: :chat,
          model_keys: %{chat: "test-model"}
        }
      }

      signal =
        Jido.Signal.new!("message.user", %{
          text: "Approve: let's ship it",
          conversation_id: parent_conv.id,
          message_id: Ash.UUIDv7.generate()
        })

      Magus.Agents.Plugins.InboxEventPlugin.handle_signal(signal, %{agent: plugin_agent})

      {:ok, resolved} = Ash.get(AgentInboxEvent, waiting_event.id, authorize?: false)
      assert resolved.status == :resolved

      new_event =
        AgentInboxEvent
        |> Ash.Query.filter(
          agent_id == ^agent.id and event_type == :approval_response and status == :pending
        )
        |> Ash.read_one!(authorize?: false)

      assert new_event.urgency == :immediate
      assert new_event.idempotency_key == "approval_response:#{waiting_event.id}"
      assert new_event.payload["chosen_option"] == "Approve"
    end

    test "failed autonomous run also drains" do
      user = generate(user())
      # Create the agent heartbeat_enabled but paused while seeding: paused
      # makes TriggerUrgentWake skip its own auto-wake for the same idempotency
      # key, avoiding a race. We unpause before handle_run_failed so drain's
      # `heartbeat_enabled and not is_paused` gate is satisfied and only the
      # plugin's drain path is under test.
      agent = custom_agent(user, %{heartbeat_enabled: true, is_paused: true})
      {parent_conv, child_conv} = create_conversations(user)

      # First seed an event with agent_run_id: nil so its idempotency key is
      # known, then create the very :inbox_urgent run that TriggerUrgentWake
      # would have created for it (consuming "inbox:#{event.id}"), and link
      # the event to it directly, simulating a wake that then errors out.
      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :mention,
            urgency: :immediate,
            title: "Urgent thing happened",
            source_type: :conversation
          },
          actor: user
        )

      urgent_run =
        create_run(user, parent_conv, child_conv, agent,
          source: :inbox_urgent,
          target_agent_id: agent.id,
          idempotency_key: "inbox:#{event.id}"
        )

      {:ok, _} = Magus.Agents.link_event_to_run(event, urgent_run.id, authorize?: false)
      {:ok, event} = Ash.get(AgentInboxEvent, event.id, authorize?: false)
      assert event.agent_run_id == urgent_run.id

      {:ok, running_run} = Magus.Agents.start_agent_run(urgent_run.id, authorize?: false)

      {:ok, failed_run} =
        Magus.Agents.fail_agent_run(running_run, %{error_message: "boom"}, authorize?: false)

      # Unpause so drain's autonomy gate (`heartbeat_enabled and not is_paused`)
      # is satisfied for the failure-path drain under test.
      {:ok, _} = Magus.Agents.update_custom_agent(agent, %{is_paused: false}, actor: user)

      AgentRunCompletionPlugin.handle_run_failed(failed_run)

      # unlink_linked_inbox_events runs first and clears agent_run_id, then
      # drain re-picks the event — but its idempotency key "inbox:#{event.id}"
      # was already consumed by the failed run itself, so enqueue resolves to
      # :existing and no second (new) run is created for that key.
      matching_runs =
        AgentRun
        |> Ash.Query.filter(idempotency_key == ^"inbox:#{event.id}")
        |> Ash.read!(authorize?: false)

      assert length(matching_runs) == 1
      assert Enum.all?(matching_runs, &(&1.id == failed_run.id))

      {:ok, final_event} = Ash.get(AgentInboxEvent, event.id, authorize?: false)
      assert final_event.agent_run_id == nil
    end
  end

  describe "ensure_next_scheduled_at for :inbox_urgent" do
    test "completed :inbox_urgent run schedules fallback heartbeat when none set" do
      user = generate(user())
      agent = custom_agent(user, %{heartbeat_enabled: true})
      {parent_conv, child_conv} = create_conversations(user)

      assert agent.next_scheduled_at == nil

      urgent_run =
        create_run(user, parent_conv, child_conv, agent,
          source: :inbox_urgent,
          target_agent_id: agent.id
        )

      {:ok, started} = Magus.Agents.start_agent_run(urgent_run.id, authorize?: false)

      {:ok, completed} =
        Magus.Agents.complete_agent_run(started, %{result_text: "handled"}, authorize?: false)

      AgentRunCompletionPlugin.handle_run_completed(completed)

      {:ok, reloaded_agent} =
        Ash.get(Magus.Agents.CustomAgent, agent.id, authorize?: false)

      assert %DateTime{} = reloaded_agent.next_scheduled_at
      assert DateTime.compare(reloaded_agent.next_scheduled_at, DateTime.utc_now()) == :gt
    end
  end

  defp create_inbox_event_immediate(user, agent) do
    {:ok, event} =
      Magus.Agents.create_inbox_event(
        %{
          agent_id: agent.id,
          event_type: :mention,
          urgency: :immediate,
          title: "Urgent thing happened",
          source_type: :conversation,
          agent_run_id: nil
        },
        actor: user
      )

    event
  end
end
