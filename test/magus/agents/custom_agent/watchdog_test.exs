defmodule Magus.Agents.CustomAgent.WatchdogTest do
  @moduledoc """
  Tests the hourly heartbeat watchdog: `CustomAgent.watchdog_overdue_agents`
  read action scopes to enabled, unpaused agents whose `next_scheduled_at` is
  more than 2x their `heartbeat_default_interval_minutes` in the past, and the
  `:watchdog_reset_schedule` update resets `next_scheduled_at` to ~now and
  writes a `:watchdog_reset` activity log entry.
  """

  use Magus.DataCase, async: false

  import Magus.Generators

  require Ash.Query

  alias Magus.Agents.CustomAgent

  setup do
    user = generate(user())
    %{user: user}
  end

  defp backdate(agent, minutes_ago, user) do
    past = DateTime.add(DateTime.utc_now(), -minutes_ago, :minute)

    {:ok, agent} =
      Magus.Agents.set_custom_agent_next_scheduled_at(agent, past, actor: user)

    agent
  end

  describe "watchdog_overdue_agents read action" do
    test "includes an agent overdue by more than 2x its interval", %{user: user} do
      agent =
        custom_agent(user, %{
          heartbeat_enabled: true,
          is_paused: false,
          heartbeat_default_interval_minutes: 30
        })
        |> backdate(90, user)

      overdue =
        CustomAgent
        |> Ash.Query.for_read(:watchdog_overdue_agents)
        |> Ash.read!(authorize?: false)

      assert agent.id in Enum.map(overdue, & &1.id)
    end

    test "excludes a merely-due agent (overdue less than 2x its interval)", %{user: user} do
      agent =
        custom_agent(user, %{
          heartbeat_enabled: true,
          is_paused: false,
          heartbeat_default_interval_minutes: 30
        })
        |> backdate(45, user)

      overdue =
        CustomAgent
        |> Ash.Query.for_read(:watchdog_overdue_agents)
        |> Ash.read!(authorize?: false)

      refute agent.id in Enum.map(overdue, & &1.id)
    end

    test "excludes a paused agent", %{user: user} do
      agent =
        custom_agent(user, %{
          heartbeat_enabled: true,
          is_paused: true,
          heartbeat_default_interval_minutes: 30
        })
        |> backdate(90, user)

      overdue =
        CustomAgent
        |> Ash.Query.for_read(:watchdog_overdue_agents)
        |> Ash.read!(authorize?: false)

      refute agent.id in Enum.map(overdue, & &1.id)
    end

    test "excludes a heartbeat-disabled agent", %{user: user} do
      agent =
        custom_agent(user, %{
          heartbeat_enabled: false,
          is_paused: false,
          heartbeat_default_interval_minutes: 30
        })
        |> backdate(90, user)

      overdue =
        CustomAgent
        |> Ash.Query.for_read(:watchdog_overdue_agents)
        |> Ash.read!(authorize?: false)

      refute agent.id in Enum.map(overdue, & &1.id)
    end

    test "excludes an agent with next_scheduled_at nil", %{user: user} do
      agent =
        custom_agent(user, %{
          heartbeat_enabled: true,
          is_paused: false,
          heartbeat_default_interval_minutes: 30
        })

      assert agent.next_scheduled_at == nil

      overdue =
        CustomAgent
        |> Ash.Query.for_read(:watchdog_overdue_agents)
        |> Ash.read!(authorize?: false)

      refute agent.id in Enum.map(overdue, & &1.id)
    end
  end

  describe "watchdog_reset_schedule update action" do
    test "resets next_scheduled_at to ~now", %{user: user} do
      agent =
        custom_agent(user, %{
          heartbeat_enabled: true,
          is_paused: false,
          heartbeat_default_interval_minutes: 30
        })
        |> backdate(90, user)

      before_reset = DateTime.utc_now()

      {:ok, updated} =
        agent
        |> Ash.Changeset.for_update(:watchdog_reset_schedule, %{})
        |> Ash.update(authorize?: false)

      after_reset = DateTime.utc_now()

      assert DateTime.compare(updated.next_scheduled_at, before_reset) in [:gt, :eq]
      assert DateTime.compare(updated.next_scheduled_at, after_reset) in [:lt, :eq]
    end

    test "writes a :watchdog_reset activity log entry", %{user: user} do
      agent =
        custom_agent(user, %{
          heartbeat_enabled: true,
          is_paused: false,
          heartbeat_default_interval_minutes: 30
        })
        |> backdate(90, user)

      {:ok, _updated} =
        agent
        |> Ash.Changeset.for_update(:watchdog_reset_schedule, %{})
        |> Ash.update(authorize?: false)

      logs =
        Magus.Agents.AgentActivityLog
        |> Ash.Query.for_read(:for_agent, %{agent_id: agent.id})
        |> Ash.read!(authorize?: false)

      assert Enum.any?(logs, fn log ->
               log.activity_type == :watchdog_reset and
                 log.summary == "Watchdog reset overdue heartbeat schedule" and
                 log.details["was"] != nil
             end)
    end
  end
end
