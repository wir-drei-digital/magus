defmodule Magus.Agents.AgentInboxEventTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  setup do
    user = generate(user())
    agent = custom_agent(user)

    %{user: user, agent: agent}
  end

  describe "create" do
    test "creates a pending event with required fields", %{user: user, agent: agent} do
      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :mention,
            title: "You were mentioned",
            source_type: :conversation
          },
          actor: user
        )

      assert event.agent_id == agent.id
      assert event.user_id == user.id
      assert event.event_type == :mention
      assert event.status == :pending
      assert event.urgency == :deferred
      assert event.title == "You were mentioned"
      assert event.source_type == :conversation
      assert event.payload == %{}
      assert event.metadata == %{}
    end

    test "creates an immediate urgency event", %{user: user, agent: agent} do
      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :approval_response,
            urgency: :immediate,
            title: "Approval needed",
            source_type: :agent
          },
          actor: user
        )

      assert event.urgency == :immediate
      assert event.event_type == :approval_response
    end

    test "creates with optional fields", %{user: user, agent: agent} do
      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :integration,
            title: "New email",
            summary: "Email from boss",
            source_type: :integration,
            source_id: "msg_123",
            source_url: "https://mail.example.com/msg/123",
            payload: %{"subject" => "Hello"},
            metadata: %{"provider" => "gmail"}
          },
          actor: user
        )

      assert event.summary == "Email from boss"
      assert event.source_id == "msg_123"
      assert event.source_url == "https://mail.example.com/msg/123"
      assert event.payload == %{"subject" => "Hello"}
      assert event.metadata == %{"provider" => "gmail"}
    end
  end

  describe "status transitions" do
    test "pending -> processing", %{user: user, agent: agent} do
      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :heartbeat,
            title: "Heartbeat",
            source_type: :scheduler
          },
          actor: user
        )

      assert event.status == :pending

      {:ok, event} = Magus.Agents.start_processing_event(event, actor: user)

      assert event.status == :processing
    end

    test "pending -> resolved with metadata", %{user: user, agent: agent} do
      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :task_assigned,
            title: "New task",
            source_type: :agent
          },
          actor: user
        )

      {:ok, event} =
        Magus.Agents.resolve_event(
          event,
          %{resolved_by: :agent, resolution_note: "Handled via reply"},
          actor: user
        )

      assert event.status == :resolved
      assert event.resolved_by == :agent
      assert event.resolution_note == "Handled via reply"
      assert event.resolved_at != nil
    end

    test "pending -> dismissed", %{user: user, agent: agent} do
      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :content,
            title: "Old news",
            source_type: :integration
          },
          actor: user
        )

      {:ok, event} =
        Magus.Agents.dismiss_event(event, %{resolution_note: "Not relevant"}, actor: user)

      assert event.status == :dismissed
      assert event.resolved_by == :user
      assert event.resolved_at != nil
    end

    test "pending -> waiting (blocked on subtask)", %{user: user, agent: agent} do
      task_id = Ash.UUIDv7.generate()

      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :task_assigned,
            title: "Delegated task",
            source_type: :agent
          },
          actor: user
        )

      {:ok, event} = Magus.Agents.mark_event_waiting(event, %{task_id: task_id}, actor: user)

      assert event.status == :waiting
      assert event.task_id == task_id
    end

    test "expire sets expired status and resolved_by: expiry", %{user: user, agent: agent} do
      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :system,
            title: "Expiring event",
            source_type: :system,
            expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
          },
          actor: user
        )

      {:ok, event} = Magus.Agents.expire_event(event, actor: user)

      assert event.status == :expired
      assert event.resolved_by == :expiry
      assert event.resolved_at != nil
    end
  end

  describe "idempotency" do
    test "prevents duplicate events with same idempotency_key for same agent", %{
      user: user,
      agent: agent
    } do
      key = "mention-conv-#{Ash.UUIDv7.generate()}"

      attrs = %{
        agent_id: agent.id,
        event_type: :mention,
        title: "Mentioned in conversation",
        source_type: :conversation,
        idempotency_key: key
      }

      {:ok, _event} = Magus.Agents.create_inbox_event(attrs, actor: user)

      assert {:error, _} = Magus.Agents.create_inbox_event(attrs, actor: user)
    end

    test "allows same idempotency_key for different agents", %{user: user, agent: agent} do
      agent2 = custom_agent(user)
      key = "shared-key-#{System.unique_integer([:positive])}"

      attrs = fn a ->
        %{
          agent_id: a.id,
          event_type: :mention,
          title: "Mention",
          source_type: :conversation,
          idempotency_key: key
        }
      end

      {:ok, _} = Magus.Agents.create_inbox_event(attrs.(agent), actor: user)
      {:ok, _} = Magus.Agents.create_inbox_event(attrs.(agent2), actor: user)
    end

    test "prevents duplicate events with same content_hash for same agent", %{
      user: user,
      agent: agent
    } do
      hash = "sha256:abc123"

      attrs = %{
        agent_id: agent.id,
        event_type: :content,
        title: "Content event",
        source_type: :integration,
        content_hash: hash
      }

      {:ok, _event} = Magus.Agents.create_inbox_event(attrs, actor: user)

      assert {:error, _} = Magus.Agents.create_inbox_event(attrs, actor: user)
    end
  end

  describe "create_waiting" do
    test "creates an event with status :waiting", %{user: user, agent: agent} do
      {:ok, event} =
        Magus.Agents.create_waiting_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :approval_response,
            title: "Waiting for approval",
            source_type: :conversation,
            source_id: Ash.UUIDv7.generate()
          },
          actor: user
        )

      assert event.status == :waiting
      assert event.agent_id == agent.id
      assert event.user_id == user.id
      assert event.event_type == :approval_response
    end
  end

  describe "by_idempotency_key" do
    test "finds an event by idempotency key", %{user: user, agent: agent} do
      key = "idem-key-#{System.unique_integer([:positive])}"

      {:ok, created} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :mention,
            title: "Idempotent event",
            source_type: :conversation,
            idempotency_key: key
          },
          actor: user
        )

      {:ok, [found]} = Magus.Agents.get_event_by_idempotency_key(key, actor: user)

      assert found.id == created.id
      assert found.idempotency_key == key
    end

    test "returns empty list for non-existent idempotency key", %{user: user} do
      {:ok, results} =
        Magus.Agents.get_event_by_idempotency_key("does-not-exist-key", actor: user)

      assert results == []
    end
  end

  describe "waiting_approval_for_conversation" do
    test "finds a waiting approval_response event for a conversation", %{user: user, agent: agent} do
      conversation_id = Ash.UUIDv7.generate()

      {:ok, event} =
        Magus.Agents.create_waiting_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :approval_response,
            title: "Approval needed",
            source_type: :conversation,
            source_id: conversation_id
          },
          actor: user
        )

      {:ok, [found]} =
        Magus.Agents.get_waiting_approval(conversation_id, actor: user)

      assert found.id == event.id
      assert found.status == :waiting
      assert found.event_type == :approval_response
      assert found.source_id == conversation_id
    end

    test "returns empty list when no waiting approval exists for conversation", %{user: user} do
      {:ok, results} =
        Magus.Agents.get_waiting_approval(Ash.UUIDv7.generate(), actor: user)

      assert results == []
    end

    test "does not return resolved approval events", %{user: user, agent: agent} do
      conversation_id = Ash.UUIDv7.generate()

      {:ok, event} =
        Magus.Agents.create_waiting_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :approval_response,
            title: "Old approval",
            source_type: :conversation,
            source_id: conversation_id
          },
          actor: user
        )

      {:ok, _} = Magus.Agents.resolve_event(event, %{resolved_by: :agent}, actor: user)

      {:ok, results} = Magus.Agents.get_waiting_approval(conversation_id, actor: user)

      assert results == []
    end
  end

  describe "agent_run linkage" do
    test "agent_run_id can be set and read back", %{user: user, agent: agent} do
      parent = generate(conversation(actor: user))

      run =
        sub_agent_run(
          source_conversation_id: parent.id,
          target_conversation_id: parent.id,
          target_agent_id: agent.id,
          initiator_user_id: user.id,
          objective: "test"
        )

      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :content,
            urgency: :deferred,
            title: "Test event",
            source_type: :integration,
            agent_run_id: run.id
          },
          actor: user
        )

      assert event.agent_run_id == run.id

      loaded = Ash.get!(Magus.Agents.AgentInboxEvent, event.id, load: [:agent_run], actor: user)
      assert loaded.agent_run.id == run.id
    end

    test "rejects invalid agent_run_id at FK level", %{user: user, agent: agent} do
      bad_id = Ash.UUID.generate()

      result =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :content,
            urgency: :deferred,
            title: "Bad",
            source_type: :integration,
            agent_run_id: bad_id
          },
          actor: user
        )

      assert match?({:error, _}, result)
    end
  end

  describe "query actions" do
    test "pending_for_agent returns pending and waiting events sorted by urgency then inserted_at",
         %{user: user, agent: agent} do
      {:ok, deferred} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :content,
            urgency: :deferred,
            title: "Deferred",
            source_type: :integration
          },
          actor: user
        )

      {:ok, immediate} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :mention,
            urgency: :immediate,
            title: "Immediate",
            source_type: :conversation
          },
          actor: user
        )

      {:ok, waiting} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :task_assigned,
            urgency: :deferred,
            title: "Waiting",
            source_type: :agent
          },
          actor: user
        )

      {:ok, waiting} = Magus.Agents.mark_event_waiting(waiting, %{}, actor: user)

      {:ok, resolved} =
        Magus.Agents.create_inbox_event(
          %{agent_id: agent.id, event_type: :system, title: "Resolved", source_type: :system},
          actor: user
        )

      {:ok, resolved} = Magus.Agents.resolve_event(resolved, %{resolved_by: :agent}, actor: user)

      {:ok, events} = Magus.Agents.list_pending_events(agent.id, actor: user)

      ids = Enum.map(events, & &1.id)

      # resolved should not be in results
      refute resolved.id in ids

      # immediate should come before deferred (urgency: :asc, :immediate < :deferred alphabetically)
      assert immediate.id in ids
      assert deferred.id in ids
      assert waiting.id in ids

      immediate_idx = Enum.find_index(events, &(&1.id == immediate.id))
      deferred_idx = Enum.find_index(events, &(&1.id == deferred.id))
      assert immediate_idx < deferred_idx
    end

    test "for_agent returns all events for an agent sorted by inserted_at desc", %{
      user: user,
      agent: agent
    } do
      {:ok, e1} =
        Magus.Agents.create_inbox_event(
          %{agent_id: agent.id, event_type: :heartbeat, title: "E1", source_type: :scheduler},
          actor: user
        )

      {:ok, e2} =
        Magus.Agents.create_inbox_event(
          %{agent_id: agent.id, event_type: :mention, title: "E2", source_type: :conversation},
          actor: user
        )

      {:ok, events} = Magus.Agents.list_agent_events(agent.id, actor: user)

      ids = Enum.map(events, & &1.id)
      assert e1.id in ids
      assert e2.id in ids

      # sorted desc — e2 inserted after e1 so should appear first
      e1_idx = Enum.find_index(events, &(&1.id == e1.id))
      e2_idx = Enum.find_index(events, &(&1.id == e2.id))
      assert e2_idx < e1_idx
    end

    test "for_agent does not return another agent's events", %{user: user, agent: agent} do
      agent2 = custom_agent(user)

      {:ok, _} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :mention,
            title: "Agent 1 event",
            source_type: :conversation
          },
          actor: user
        )

      {:ok, _} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent2.id,
            event_type: :mention,
            title: "Agent 2 event",
            source_type: :conversation
          },
          actor: user
        )

      {:ok, events} = Magus.Agents.list_agent_events(agent.id, actor: user)

      assert Enum.all?(events, &(&1.agent_id == agent.id))
    end
  end

  describe "link_to_run / unlink_from_run / resolve_via_run" do
    setup %{user: user, agent: agent} do
      parent = generate(conversation(actor: user))

      run =
        sub_agent_run(
          source_conversation_id: parent.id,
          target_conversation_id: parent.id,
          target_agent_id: agent.id,
          initiator_user_id: user.id,
          objective: "test"
        )

      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :content,
            urgency: :deferred,
            title: "Test event",
            source_type: :integration
          },
          actor: user
        )

      %{run: run, event: event}
    end

    test "link_to_run sets agent_run_id and keeps status pending", %{
      event: event,
      run: run,
      user: user
    } do
      {:ok, linked} = Magus.Agents.link_event_to_run(event, run.id, actor: user)
      assert linked.agent_run_id == run.id
      assert linked.status == :pending
    end

    test "unlink_from_run clears agent_run_id and keeps status", %{
      event: event,
      run: run,
      user: user
    } do
      {:ok, linked} = Magus.Agents.link_event_to_run(event, run.id, actor: user)
      {:ok, unlinked} = Magus.Agents.unlink_event_from_run(linked, actor: user)
      assert unlinked.agent_run_id == nil
      assert unlinked.status == :pending
    end

    test "resolve_via_run sets resolved + resolved_by", %{event: event, run: run, user: user} do
      {:ok, linked} = Magus.Agents.link_event_to_run(event, run.id, actor: user)
      {:ok, resolved} = Magus.Agents.resolve_event_via_run(linked, actor: user)
      assert resolved.status == :resolved
      assert resolved.resolved_by == :run_completed
      assert resolved.resolved_at != nil
    end
  end
end
