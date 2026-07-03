defmodule Magus.Agents.TriggerUrgentWakeTest do
  use Magus.DataCase, async: false

  import Magus.Generators
  require Ash.Query

  alias Magus.Agents.AgentRun

  setup do
    user = generate(user())

    # :inbox_urgent is a budget-gated source (like :heartbeat): the owner's
    # PAYG spend budget is checked. Without an active subscription,
    # `get_effective_limits/1` falls back to zero spend budget and every
    # enqueue is rejected with `:insufficient_spend_budget`. Give the user a
    # free plan so the spend-budget gate passes.
    free_plan = ensure_free_plan()

    {:ok, _subscription} =
      Magus.Usage.create_user_subscription(
        %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
        authorize?: false
      )

    agent = generate(custom_agent(user, %{heartbeat_enabled: true, is_paused: false}))
    %{user: user, agent: agent}
  end

  defp create_event(user, agent, attrs) do
    base = %{
      agent_id: agent.id,
      event_type: :task_assigned,
      urgency: :immediate,
      title: "Test urgent event",
      source_type: :system
    }

    Magus.Agents.create_inbox_event(Map.merge(base, attrs), actor: user)
  end

  defp runs_for(agent) do
    AgentRun
    |> Ash.Query.filter(target_agent_id == ^agent.id and source == :inbox_urgent)
    |> Ash.read!(authorize?: false)
  end

  defp seed_agent_run(user, agent, status_fun) do
    {:ok, home} = Magus.Agents.Support.HomeConversation.ensure(user.id, agent.id)

    {:ok, run} =
      Magus.Agents.create_agent_run(
        %{
          kind: :delegate,
          source: :heartbeat,
          source_conversation_id: home.id,
          target_agent_id: agent.id,
          target_conversation_id: home.id,
          initiator_user_id: user.id,
          request_id: "hb-#{Ash.UUID.generate()}",
          objective: "x"
        },
        authorize?: false
      )

    status_fun.(run)
  end

  defp seed_running_heartbeat_run(user, agent) do
    seed_agent_run(user, agent, fn run ->
      Magus.Agents.start_agent_run(run, authorize?: false)
    end)
  end

  defp seed_completed_urgent_run(user, agent) do
    seed_agent_run(user, agent, fn run ->
      {:ok, started} = Magus.Agents.start_agent_run(run, authorize?: false)
      Magus.Agents.complete_agent_run(started, authorize?: false)
    end)
  end

  test "immediate event enqueues an :inbox_urgent run pre-linked to the event",
       %{user: user, agent: agent} do
    {:ok, event} = create_event(user, agent, %{})

    assert [run] = runs_for(agent)
    assert run.idempotency_key == "inbox:#{event.id}"
    assert run.initiator_user_id == user.id

    event = Ash.get!(Magus.Agents.AgentInboxEvent, event.id, authorize?: false)
    assert event.agent_run_id == run.id

    logs =
      Magus.Agents.AgentActivityLog
      |> Ash.Query.for_read(:for_agent, %{agent_id: agent.id})
      |> Ash.read!(authorize?: false)

    assert Enum.any?(logs, fn log ->
             log.activity_type == :wake_urgent and
               log.summary == "Urgent wake for inbox event: #{event.title}"
           end)
  end

  test "deferred event does not enqueue", %{user: user, agent: agent} do
    {:ok, _} = create_event(user, agent, %{urgency: :deferred})
    assert runs_for(agent) == []
  end

  test "paused agent does not wake", %{user: user} do
    agent = generate(custom_agent(user, %{heartbeat_enabled: true, is_paused: true}))
    {:ok, _} = create_event(user, agent, %{})
    assert runs_for(agent) == []
  end

  test "heartbeat-disabled agent does not wake", %{user: user} do
    agent = generate(custom_agent(user, %{heartbeat_enabled: false}))
    {:ok, _} = create_event(user, agent, %{})
    assert runs_for(agent) == []
  end

  test "event created with agent_run_id already set does not wake",
       %{user: user, agent: agent} do
    # simulate an event pre-linked by a run in flight (the seeded run itself
    # is a completed :heartbeat run, so it never shows up in `runs_for/1`,
    # which filters on source == :inbox_urgent; the assertion here is that
    # no NEW :inbox_urgent run gets created for the pre-linked event)
    {:ok, run} = seed_completed_urgent_run(user, agent)
    {:ok, _} = create_event(user, agent, %{agent_run_id: run.id})
    assert runs_for(agent) == []
  end

  test "in-flight autonomous run: event stays pending, unlinked, no run created",
       %{user: user, agent: agent} do
    # seed a RUNNING :heartbeat run for the agent so the gate rejects
    seed_running_heartbeat_run(user, agent)
    {:ok, event} = create_event(user, agent, %{})

    assert runs_for(agent) == []
    event = Ash.get!(Magus.Agents.AgentInboxEvent, event.id, authorize?: false)
    assert event.status == :pending
    assert is_nil(event.agent_run_id)
  end

  describe "nested-transaction deferral" do
    setup do
      # The deferred wake runs on a supervised task in a separate process;
      # shared-mode sandbox lets it reach the committed rows. Scoped to this
      # describe block so it doesn't affect the synchronous tests above.
      Ecto.Adapters.SQL.Sandbox.mode(Magus.Repo, {:shared, self()})
      :ok
    end

    defp assert_eventually(fun, timeout_ms \\ 3_000, interval_ms \\ 100) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      do_assert_eventually(fun, deadline, interval_ms)
    end

    defp do_assert_eventually(fun, deadline, interval_ms) do
      if fun.() do
        :ok
      else
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("condition not met within timeout")
        else
          Process.sleep(interval_ms)
          do_assert_eventually(fun, deadline, interval_ms)
        end
      end
    end

    test "event created inside a transaction does not wake synchronously, wakes after commit",
         %{user: user, agent: agent} do
      {:ok, event} =
        Magus.Repo.transaction(fn ->
          {:ok, event} = create_event(user, agent, %{})

          # Still inside the open outer transaction: the after_transaction hook
          # ran synchronously here but must have DEFERRED, so no run yet.
          assert runs_for(agent) == []

          event
        end)

      # After commit the deferred task polls for the committed event, enqueues
      # the run, then links it back to the event. Wait for the linkage so we
      # don't race the still-running deferred task.
      assert_eventually(fn ->
        event = Ash.get!(Magus.Agents.AgentInboxEvent, event.id, authorize?: false)
        not is_nil(event.agent_run_id)
      end)

      assert [run] = runs_for(agent)
      assert run.idempotency_key == "inbox:#{event.id}"

      linked = Ash.get!(Magus.Agents.AgentInboxEvent, event.id, authorize?: false)
      assert linked.agent_run_id == run.id
    end

    test "rolled-back event never wakes", %{user: user, agent: agent} do
      captured_id =
        Magus.Repo.transaction(fn ->
          {:ok, event} = create_event(user, agent, %{})
          id = event.id
          # Abort the outer transaction: the event row is rolled back.
          Magus.Repo.rollback({:aborted, id})
        end)

      assert {:error, {:aborted, event_id}} = captured_id

      # Give the deferred poller its full window to (not) find the event.
      Process.sleep(1_000)

      assert runs_for(agent) == []
      assert {:error, _} = Ash.get(Magus.Agents.AgentInboxEvent, event_id, authorize?: false)
    end
  end
end
