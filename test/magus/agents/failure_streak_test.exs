defmodule Magus.Agents.FailureStreakTest do
  @moduledoc """
  Tests failure-streak escalation: `FailureStreak.check_and_escalate/1` scans
  the most recent terminal autonomous `AgentRun`s for an agent (newest
  first), counts the leading run of consecutive failures (`:error` or
  `:timed_out`), and escalates:

    * exactly 3 consecutive failures -> notify the owner (once; no repeat
      notification at 4, 5, ... up to the pause threshold)
    * >= 10 consecutive failures -> pause the agent with a visible
      `pause_reason` + notify

  Runs are ordered by `completed_at` (see module doc for why, not
  `inserted_at`); tests backdate `completed_at` via `Repo.update_all` to
  control ordering deterministically. Only autonomous sources
  (`:heartbeat`, `:manual_trigger`, `:inbox_urgent`) count toward the
  streak — `:mention` runs are excluded.
  """

  use Magus.DataCase, async: false

  import Magus.Generators

  require Ash.Query

  alias Magus.Agents.AgentRun
  alias Magus.Agents.Support.FailureStreak

  setup do
    user = generate(user())
    parent = generate(conversation(actor: user))
    agent = generate(custom_agent(user))

    %{user: user, parent: parent, agent: agent}
  end

  # Creates a terminal autonomous run for `agent`, transitions it to the
  # given terminal `status`, then backdates `completed_at` (and
  # `inserted_at`, to keep it consistent) to `minutes_ago` in the past so
  # tests can control streak ordering deterministically.
  defp terminal_run(agent, parent, status, minutes_ago, opts \\ []) do
    source = Keyword.get(opts, :source, :heartbeat)

    run =
      sub_agent_run(
        source_conversation_id: parent.id,
        target_agent_id: agent.id,
        initiator_user_id: agent.user_id,
        source: source,
        objective: "Autonomous check #{System.unique_integer([:positive])}"
      )

    {:ok, run} = Magus.Agents.start_agent_run(run, authorize?: false)

    {:ok, run} =
      case status do
        :error ->
          Magus.Agents.fail_agent_run(run, %{error_message: "boom"}, authorize?: false)

        :timed_out ->
          Magus.Agents.timeout_agent_run(run, authorize?: false)

        :complete ->
          Magus.Agents.complete_agent_run(run, %{result_text: "ok"}, authorize?: false)
      end

    backdated = DateTime.add(DateTime.utc_now(), -minutes_ago, :minute)

    AgentRun
    |> Ecto.Query.where([r], r.id == ^run.id)
    |> Magus.Repo.update_all(set: [completed_at: backdated, inserted_at: backdated])

    {:ok, run} = Magus.Agents.get_agent_run(run.id, authorize?: false)
    run
  end

  defp notifications_for(user) do
    Magus.Notifications.Notification
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.read!(authorize?: false)
  end

  describe "check_and_escalate/1" do
    test "streak of 3 notifies the owner and does not pause", %{
      user: user,
      parent: parent,
      agent: agent
    } do
      # Oldest first for readability; minutes_ago descending = newest last.
      terminal_run(agent, parent, :complete, 40)
      terminal_run(agent, parent, :error, 30)
      terminal_run(agent, parent, :error, 20)
      terminal_run(agent, parent, :error, 10)

      assert {:ok, 3} = FailureStreak.check_and_escalate(agent.id)

      notifications = notifications_for(user)
      assert length(notifications) == 1
      assert hd(notifications).notification_type == :system

      {:ok, reloaded} = Magus.Agents.get_custom_agent(agent.id, authorize?: false)
      refute reloaded.is_paused
      assert reloaded.pause_reason == nil
    end

    test "streak of 2 does not notify", %{user: user, parent: parent, agent: agent} do
      terminal_run(agent, parent, :complete, 30)
      terminal_run(agent, parent, :error, 20)
      terminal_run(agent, parent, :error, 10)

      assert {:ok, 2} = FailureStreak.check_and_escalate(agent.id)
      assert notifications_for(user) == []
    end

    test "streak of 4 does not fire a new notification (only exactly 3)", %{
      user: user,
      parent: parent,
      agent: agent
    } do
      terminal_run(agent, parent, :complete, 50)
      terminal_run(agent, parent, :error, 40)
      terminal_run(agent, parent, :error, 30)
      terminal_run(agent, parent, :error, 20)
      terminal_run(agent, parent, :error, 10)

      assert {:ok, 4} = FailureStreak.check_and_escalate(agent.id)
      assert notifications_for(user) == []
    end

    test "streak of 10 pauses the agent with a visible reason and notifies", %{
      user: user,
      parent: parent,
      agent: agent
    } do
      for minutes_ago <- Enum.to_list(10..1//-1) do
        terminal_run(agent, parent, :error, minutes_ago)
      end

      assert {:ok, 10} = FailureStreak.check_and_escalate(agent.id)

      {:ok, reloaded} = Magus.Agents.get_custom_agent(agent.id, authorize?: false)
      assert reloaded.is_paused
      assert reloaded.pause_reason =~ "10 consecutive failed autonomous runs"

      notifications = notifications_for(user)
      assert length(notifications) == 1
    end

    test "newest run complete resets streak to 0 even with 10 older failures", %{
      user: user,
      parent: parent,
      agent: agent
    } do
      for minutes_ago <- Enum.to_list(11..2//-1) do
        terminal_run(agent, parent, :error, minutes_ago)
      end

      terminal_run(agent, parent, :complete, 1)

      assert {:ok, 0} = FailureStreak.check_and_escalate(agent.id)

      {:ok, reloaded} = Magus.Agents.get_custom_agent(agent.id, authorize?: false)
      refute reloaded.is_paused
      assert notifications_for(user) == []
    end

    test "mention-source failures do not count toward the streak", %{
      user: user,
      parent: parent,
      agent: agent
    } do
      terminal_run(agent, parent, :error, 40, source: :mention)
      terminal_run(agent, parent, :error, 30, source: :mention)
      terminal_run(agent, parent, :error, 20, source: :mention)
      terminal_run(agent, parent, :error, 10, source: :heartbeat)

      assert {:ok, 1} = FailureStreak.check_and_escalate(agent.id)
      assert notifications_for(user) == []
    end

    test "returns {:ok, 0} for nil agent_id without raising" do
      assert {:ok, 0} = FailureStreak.check_and_escalate(nil)
    end
  end
end
