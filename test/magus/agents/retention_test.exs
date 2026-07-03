defmodule Magus.Agents.RetentionTest do
  @moduledoc """
  Tests Phase 4 retention + expiry triggers:

    * `AgentInboxEvent.:expire` via the `is_expiry_due` calc/`:expiry_due` read
    * `AgentInboxEvent.:prune` via the `is_prunable` calc/`:prunable` read
    * `AgentRun.:prune` via the `is_prunable` calc/`:prunable_runs` read
    * `AgentActivityLog.:prune` via the `is_prunable` calc/`:prunable` read

  Backdating happens via `Repo.update_all` AFTER the record reaches its
  terminal state, since any Ash update touches `updated_at`.
  """

  use Magus.DataCase, async: false

  import Magus.Generators

  require Ash.Query

  alias Magus.Agents.{AgentActivityLog, AgentInboxEvent, AgentRun}

  setup do
    user = generate(user())
    conversation = generate(conversation(actor: user))
    agent = generate(custom_agent(user))

    %{user: user, conversation: conversation, agent: agent}
  end

  defp backdate_updated_at(schema, id, days_ago) do
    backdated = DateTime.add(DateTime.utc_now(), -days_ago, :day)

    schema
    |> Ecto.Query.where([r], r.id == ^id)
    |> Magus.Repo.update_all(set: [updated_at: backdated])
  end

  defp backdate_inserted_at(schema, id, days_ago) do
    backdated = DateTime.add(DateTime.utc_now(), -days_ago, :day)

    schema
    |> Ecto.Query.where([r], r.id == ^id)
    |> Magus.Repo.update_all(set: [inserted_at: backdated])
  end

  defp backdate_expires_at(schema, id, hours_ago) do
    backdated = DateTime.add(DateTime.utc_now(), -hours_ago, :hour)

    schema
    |> Ecto.Query.where([r], r.id == ^id)
    |> Magus.Repo.update_all(set: [expires_at: backdated])
  end

  describe "AgentInboxEvent expiry" do
    test "expiry_due read action selects a pending event past expires_at and excludes one not yet due",
         %{agent: agent, user: user} do
      due =
        Magus.Agents.create_inbox_event!(
          %{
            agent_id: agent.id,
            event_type: :mention,
            urgency: :immediate,
            title: "Due for expiry",
            source_type: :conversation,
            expires_at: DateTime.add(DateTime.utc_now(), 1, :hour)
          },
          actor: user
        )

      backdate_expires_at(AgentInboxEvent, due.id, 2)

      not_due =
        Magus.Agents.create_inbox_event!(
          %{
            agent_id: agent.id,
            event_type: :mention,
            urgency: :immediate,
            title: "Not yet due",
            source_type: :conversation,
            expires_at: DateTime.add(DateTime.utc_now(), 1, :hour)
          },
          actor: user
        )

      results =
        AgentInboxEvent
        |> Ash.Query.for_read(:expiry_due)
        |> Ash.read!(authorize?: false)

      result_ids = Enum.map(results, & &1.id)

      assert due.id in result_ids
      refute not_due.id in result_ids
    end

    test "expiry_due excludes events already in a terminal status even if expires_at has passed",
         %{agent: agent, user: user} do
      resolved =
        Magus.Agents.create_inbox_event!(
          %{
            agent_id: agent.id,
            event_type: :mention,
            urgency: :immediate,
            title: "Already resolved",
            source_type: :conversation,
            expires_at: DateTime.add(DateTime.utc_now(), 1, :hour)
          },
          actor: user
        )

      {:ok, resolved} =
        resolved
        |> Ash.Changeset.for_update(:resolve, %{}, authorize?: false)
        |> Ash.update()

      backdate_expires_at(AgentInboxEvent, resolved.id, 2)

      results =
        AgentInboxEvent
        |> Ash.Query.for_read(:expiry_due)
        |> Ash.read!(authorize?: false)

      refute resolved.id in Enum.map(results, & &1.id)
    end

    test ":expire marks a due pending event as :expired", %{agent: agent, user: user} do
      event =
        Magus.Agents.create_inbox_event!(
          %{
            agent_id: agent.id,
            event_type: :mention,
            urgency: :immediate,
            title: "Due for expiry",
            source_type: :conversation,
            expires_at: DateTime.add(DateTime.utc_now(), 1, :hour)
          },
          actor: user
        )

      backdate_expires_at(AgentInboxEvent, event.id, 2)

      {:ok, event} = Ash.get(AgentInboxEvent, event.id, authorize?: false)

      {:ok, expired} =
        event
        |> Ash.Changeset.for_update(:expire, %{}, authorize?: false)
        |> Ash.update()

      assert expired.status == :expired
    end
  end

  describe "AgentInboxEvent pruning" do
    test "prunable read action includes a 31-day-old resolved event and excludes a 29-day-old one",
         %{agent: agent, user: user} do
      old_resolved =
        Magus.Agents.create_inbox_event!(
          %{
            agent_id: agent.id,
            event_type: :mention,
            urgency: :deferred,
            title: "Old resolved",
            source_type: :conversation
          },
          actor: user
        )

      {:ok, old_resolved} =
        old_resolved
        |> Ash.Changeset.for_update(:resolve, %{}, authorize?: false)
        |> Ash.update()

      backdate_updated_at(AgentInboxEvent, old_resolved.id, 31)

      recent_resolved =
        Magus.Agents.create_inbox_event!(
          %{
            agent_id: agent.id,
            event_type: :mention,
            urgency: :deferred,
            title: "Recent resolved",
            source_type: :conversation
          },
          actor: user
        )

      {:ok, recent_resolved} =
        recent_resolved
        |> Ash.Changeset.for_update(:resolve, %{}, authorize?: false)
        |> Ash.update()

      backdate_updated_at(AgentInboxEvent, recent_resolved.id, 29)

      results =
        AgentInboxEvent
        |> Ash.Query.for_read(:prunable)
        |> Ash.read!(authorize?: false)

      result_ids = Enum.map(results, & &1.id)

      assert old_resolved.id in result_ids
      refute recent_resolved.id in result_ids
    end

    test "prunable read action never selects a non-terminal (pending) event, however old",
         %{agent: agent, user: user} do
      old_pending =
        Magus.Agents.create_inbox_event!(
          %{
            agent_id: agent.id,
            event_type: :mention,
            urgency: :deferred,
            title: "Old but still pending",
            source_type: :conversation
          },
          actor: user
        )

      backdate_updated_at(AgentInboxEvent, old_pending.id, 400)

      results =
        AgentInboxEvent
        |> Ash.Query.for_read(:prunable)
        |> Ash.read!(authorize?: false)

      refute old_pending.id in Enum.map(results, & &1.id)
    end

    test ":prune destroys a 31-day-old resolved event", %{agent: agent, user: user} do
      event =
        Magus.Agents.create_inbox_event!(
          %{
            agent_id: agent.id,
            event_type: :mention,
            urgency: :deferred,
            title: "To be pruned",
            source_type: :conversation
          },
          actor: user
        )

      {:ok, event} =
        event
        |> Ash.Changeset.for_update(:resolve, %{}, authorize?: false)
        |> Ash.update()

      backdate_updated_at(AgentInboxEvent, event.id, 31)

      {:ok, event} = Ash.get(AgentInboxEvent, event.id, authorize?: false)

      :ok =
        event
        |> Ash.Changeset.for_destroy(:prune, %{}, authorize?: false)
        |> Ash.destroy()

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.get(AgentInboxEvent, event.id, authorize?: false)
    end
  end

  describe "AgentRun pruning" do
    test "prunable_runs read action includes a 91-day-old complete run and excludes an 89-day-old one",
         %{conversation: conversation} do
      old_complete =
        sub_agent_run(source_conversation_id: conversation.id, objective: "Old complete")

      {:ok, old_complete} =
        old_complete
        |> Ash.Changeset.for_update(:complete, %{}, authorize?: false)
        |> Ash.update()

      backdate_updated_at(AgentRun, old_complete.id, 91)

      recent_complete =
        sub_agent_run(source_conversation_id: conversation.id, objective: "Recent complete")

      {:ok, recent_complete} =
        recent_complete
        |> Ash.Changeset.for_update(:complete, %{}, authorize?: false)
        |> Ash.update()

      backdate_updated_at(AgentRun, recent_complete.id, 89)

      results =
        AgentRun
        |> Ash.Query.for_read(:prunable_runs)
        |> Ash.read!(authorize?: false)

      result_ids = Enum.map(results, & &1.id)

      assert old_complete.id in result_ids
      refute recent_complete.id in result_ids
    end

    test "prunable_runs never selects a non-terminal (running) run, however old",
         %{conversation: conversation} do
      old_running =
        sub_agent_run(source_conversation_id: conversation.id, objective: "Old running")

      {:ok, old_running} =
        old_running
        |> Ash.Changeset.for_update(:start, %{}, authorize?: false)
        |> Ash.update()

      backdate_updated_at(AgentRun, old_running.id, 400)

      results =
        AgentRun
        |> Ash.Query.for_read(:prunable_runs)
        |> Ash.read!(authorize?: false)

      refute old_running.id in Enum.map(results, & &1.id)
    end

    test ":prune destroys a 91-day-old complete run and nilifies a linked inbox event's agent_run_id",
         %{conversation: conversation, agent: agent, user: user} do
      run = sub_agent_run(source_conversation_id: conversation.id, objective: "Linked run")

      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :mention,
            urgency: :immediate,
            title: "Linked to run",
            source_type: :conversation,
            agent_run_id: run.id
          },
          actor: user
        )

      assert event.agent_run_id == run.id

      {:ok, run} =
        run
        |> Ash.Changeset.for_update(:complete, %{}, authorize?: false)
        |> Ash.update()

      backdate_updated_at(AgentRun, run.id, 91)

      {:ok, run} = Magus.Agents.get_agent_run(run.id, authorize?: false)

      :ok =
        run
        |> Ash.Changeset.for_destroy(:prune, %{}, authorize?: false)
        |> Ash.destroy()

      assert {:error, %Ash.Error.Invalid{}} =
               Magus.Agents.get_agent_run(run.id, authorize?: false)

      {:ok, updated_event} = Ash.get(AgentInboxEvent, event.id, authorize?: false)
      assert updated_event.agent_run_id == nil
    end
  end

  describe "AgentActivityLog pruning" do
    test "prunable read action includes a 91-day-old log and excludes an 89-day-old one",
         %{agent: agent, user: user} do
      old_log =
        Magus.Agents.create_activity_log!(
          %{
            agent_id: agent.id,
            activity_type: :triage_completed,
            summary: "Old log"
          },
          actor: user
        )

      backdate_inserted_at(AgentActivityLog, old_log.id, 91)

      recent_log =
        Magus.Agents.create_activity_log!(
          %{
            agent_id: agent.id,
            activity_type: :triage_completed,
            summary: "Recent log"
          },
          actor: user
        )

      backdate_inserted_at(AgentActivityLog, recent_log.id, 89)

      results =
        AgentActivityLog
        |> Ash.Query.for_read(:prunable)
        |> Ash.read!(authorize?: false)

      result_ids = Enum.map(results, & &1.id)

      assert old_log.id in result_ids
      refute recent_log.id in result_ids
    end

    test ":prune destroys a 91-day-old activity log", %{agent: agent, user: user} do
      log =
        Magus.Agents.create_activity_log!(
          %{
            agent_id: agent.id,
            activity_type: :triage_completed,
            summary: "To be pruned"
          },
          actor: user
        )

      backdate_inserted_at(AgentActivityLog, log.id, 91)

      {:ok, log} = Ash.get(AgentActivityLog, log.id, authorize?: false)

      :ok =
        log
        |> Ash.Changeset.for_destroy(:prune, %{}, authorize?: false)
        |> Ash.destroy()

      assert {:error, %Ash.Error.Invalid{}} = Ash.get(AgentActivityLog, log.id, authorize?: false)
    end
  end
end
