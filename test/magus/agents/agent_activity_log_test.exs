defmodule Magus.Agents.AgentActivityLogTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  setup do
    user = generate(user())
    agent = custom_agent(user)

    %{user: user, agent: agent}
  end

  describe "create" do
    test "creates a log entry with required fields", %{user: user, agent: agent} do
      {:ok, log} =
        Magus.Agents.create_activity_log(
          %{
            agent_id: agent.id,
            activity_type: :triage_completed,
            summary: "Triage processed 3 events"
          },
          actor: user
        )

      assert log.agent_id == agent.id
      assert log.user_id == user.id
      assert log.activity_type == :triage_completed
      assert log.summary == "Triage processed 3 events"
      assert log.details == %{}
    end

    test "creates with all optional fields", %{user: user, agent: agent} do
      event_id = Ash.UUIDv7.generate()
      run_id = Ash.UUIDv7.generate()
      task_id = Ash.UUIDv7.generate()
      conv = generate(conversation(actor: user))
      conv_id = conv.id

      {:ok, log} =
        Magus.Agents.create_activity_log(
          %{
            agent_id: agent.id,
            activity_type: :run_spawned,
            summary: "Spawned research sub-agent",
            event_id: event_id,
            run_id: run_id,
            task_id: task_id,
            conversation_id: conv_id,
            details: %{"target" => "research-agent"},
            model_used: "openrouter:anthropic/claude-sonnet-4",
            tokens_used: 1200,
            estimated_cost_usd: Decimal.new("0.0024"),
            duration_ms: 850
          },
          actor: user
        )

      assert log.event_id == event_id
      assert log.run_id == run_id
      assert log.task_id == task_id
      assert log.conversation_id == conv_id
      assert log.details == %{"target" => "research-agent"}
      assert log.model_used == "openrouter:anthropic/claude-sonnet-4"
      assert log.tokens_used == 1200
      assert Decimal.equal?(log.estimated_cost_usd, Decimal.new("0.0024"))
      assert log.duration_ms == 850
    end

    test "supports all activity_type values", %{user: user, agent: agent} do
      types = [
        :triage_completed,
        :event_resolved,
        :event_dismissed,
        :task_created,
        :task_updated,
        :task_completed,
        :run_spawned,
        :run_completed,
        :run_failed,
        :approval_requested,
        :response_sent,
        :content_curated,
        :memory_updated,
        :error
      ]

      for type <- types do
        {:ok, log} =
          Magus.Agents.create_activity_log(
            %{agent_id: agent.id, activity_type: type, summary: "#{type} occurred"},
            actor: user
          )

        assert log.activity_type == type
      end
    end
  end

  describe "for_agent query" do
    test "returns logs for the given agent, sorted by inserted_at desc", %{
      user: user,
      agent: agent
    } do
      {:ok, log1} =
        Magus.Agents.create_activity_log(
          %{agent_id: agent.id, activity_type: :triage_completed, summary: "First triage"},
          actor: user
        )

      {:ok, log2} =
        Magus.Agents.create_activity_log(
          %{agent_id: agent.id, activity_type: :response_sent, summary: "Sent reply"},
          actor: user
        )

      {:ok, logs} = Magus.Agents.list_agent_activity(agent.id, actor: user)

      ids = Enum.map(logs, & &1.id)
      assert log1.id in ids
      assert log2.id in ids

      # sorted desc — log2 was inserted after log1
      log1_idx = Enum.find_index(logs, &(&1.id == log1.id))
      log2_idx = Enum.find_index(logs, &(&1.id == log2.id))
      assert log2_idx < log1_idx
    end

    test "does not return another agent's logs", %{user: user, agent: agent} do
      agent2 = custom_agent(user)

      {:ok, _} =
        Magus.Agents.create_activity_log(
          %{agent_id: agent.id, activity_type: :triage_completed, summary: "Agent 1 triage"},
          actor: user
        )

      {:ok, _} =
        Magus.Agents.create_activity_log(
          %{agent_id: agent2.id, activity_type: :triage_completed, summary: "Agent 2 triage"},
          actor: user
        )

      {:ok, logs} = Magus.Agents.list_agent_activity(agent.id, actor: user)

      assert Enum.all?(logs, &(&1.agent_id == agent.id))
    end
  end

  describe "for_user query" do
    test "returns all logs for the current actor's user_id", %{user: user, agent: agent} do
      agent2 = custom_agent(user)

      {:ok, log1} =
        Magus.Agents.create_activity_log(
          %{agent_id: agent.id, activity_type: :run_spawned, summary: "Run from agent 1"},
          actor: user
        )

      {:ok, log2} =
        Magus.Agents.create_activity_log(
          %{agent_id: agent2.id, activity_type: :run_completed, summary: "Run from agent 2"},
          actor: user
        )

      {:ok, logs} = Magus.Agents.list_user_activity(actor: user)

      ids = Enum.map(logs, & &1.id)
      assert log1.id in ids
      assert log2.id in ids
    end

    test "does not return another user's logs", %{user: user, agent: agent} do
      other_user = generate(user())
      other_agent = custom_agent(other_user)

      {:ok, _my_log} =
        Magus.Agents.create_activity_log(
          %{agent_id: agent.id, activity_type: :triage_completed, summary: "My triage"},
          actor: user
        )

      {:ok, _other_log} =
        Magus.Agents.create_activity_log(
          %{agent_id: other_agent.id, activity_type: :triage_completed, summary: "Other triage"},
          actor: other_user
        )

      {:ok, logs} = Magus.Agents.list_user_activity(actor: user)

      assert Enum.all?(logs, &(&1.user_id == user.id))
    end
  end
end
