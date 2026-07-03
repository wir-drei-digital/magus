defmodule Magus.Agents.Support.AutonomyTraceTest do
  @moduledoc """
  Tests for `Magus.Agents.Support.AutonomyTrace`, the best-effort
  AgentActivityLog writer used by autonomy machinery (heartbeat scheduler,
  urgent wakes, stale-run sweeps). Nil-safe and never raises: silent branches
  must stay observable without becoming a new source of crashes.
  """

  use Magus.DataCase, async: true

  import Magus.Generators

  require Ash.Query

  alias Magus.Agents.AgentActivityLog
  alias Magus.Agents.Support.AutonomyTrace

  setup do
    user = generate(user())
    agent = custom_agent(user)

    %{user: user, agent: agent}
  end

  defp logs_for_agent(agent_id) do
    AgentActivityLog
    |> Ash.Query.for_read(:for_agent, %{agent_id: agent_id})
    |> Ash.read!(authorize?: false)
  end

  describe "log/5" do
    test "writes an activity log entry with a new autonomy activity_type", %{
      user: user,
      agent: agent
    } do
      assert :ok =
               AutonomyTrace.log(
                 agent.id,
                 user.id,
                 :wake_skipped,
                 "Heartbeat skipped: daily run budget exhausted",
                 %{reason: "budget_exceeded"}
               )

      [log] = logs_for_agent(agent.id)

      assert log.activity_type == :wake_skipped
      assert log.summary == "Heartbeat skipped: daily run budget exhausted"
      assert log.agent_id == agent.id
      assert log.user_id == user.id
      assert log.details == %{"reason" => "budget_exceeded"}
    end

    test "defaults metadata to an empty map", %{user: user, agent: agent} do
      assert :ok = AutonomyTrace.log(agent.id, user.id, :wake_urgent, "Urgent wake")

      [log] = logs_for_agent(agent.id)

      assert log.details == %{}
    end

    test "supports :run_timed_out and :recovery activity types", %{user: user, agent: agent} do
      assert :ok = AutonomyTrace.log(agent.id, user.id, :run_timed_out, "Run timed out")
      assert :ok = AutonomyTrace.log(agent.id, user.id, :recovery, "Recovery: aborted_not_ready")

      types =
        agent.id
        |> logs_for_agent()
        |> Enum.map(& &1.activity_type)
        |> Enum.sort()

      assert types == [:recovery, :run_timed_out]
    end

    test "nil agent_id is a no-op", %{user: user, agent: agent} do
      assert :ok = AutonomyTrace.log(nil, user.id, :wake_skipped, "should not write")

      assert logs_for_agent(agent.id) == []
    end

    test "nil user_id is a no-op", %{agent: agent} do
      assert :ok = AutonomyTrace.log(agent.id, nil, :wake_skipped, "should not write")

      assert logs_for_agent(agent.id) == []
    end

    test "never raises on a bogus (non-existent) agent_id/user_id" do
      bogus_agent_id = Ash.UUIDv7.generate()
      bogus_user_id = Ash.UUIDv7.generate()

      assert :ok = AutonomyTrace.log(bogus_agent_id, bogus_user_id, :wake_skipped, "bogus")
    end

    test "never raises on a bogus activity_type", %{user: user, agent: agent} do
      assert :ok = AutonomyTrace.log(agent.id, user.id, :not_a_real_type, "bogus type")

      assert logs_for_agent(agent.id) == []
    end
  end
end
