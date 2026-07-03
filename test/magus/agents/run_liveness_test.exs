defmodule Magus.Agents.RunLivenessTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Agents.AgentRun
  alias Magus.Agents.RunLiveness

  setup do
    user = generate(user())

    free_plan = ensure_free_plan()

    {:ok, _subscription} =
      Magus.Usage.create_user_subscription(
        %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
        authorize?: false
      )

    agent = generate(custom_agent(user, %{heartbeat_enabled: true, is_paused: false}))
    %{user: user, agent: agent}
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

    run = status_fun.(run)
    {run, home}
  end

  defp seed_running_heartbeat_run(user, agent) do
    seed_agent_run(user, agent, fn run ->
      {:ok, started} = Magus.Agents.start_agent_run(run, authorize?: false)
      started
    end)
  end

  defp reload(run) do
    Ash.get!(AgentRun, run.id, authorize?: false)
  end

  test "touch updates last_heartbeat_at of running runs", %{user: user, agent: agent} do
    {run, home} = seed_running_heartbeat_run(user, agent)
    RunLiveness.reset_throttle(home.id)

    original_heartbeat = run.last_heartbeat_at

    Process.sleep(1100)

    assert :ok = RunLiveness.touch(home.id)

    reloaded = reload(run)
    assert DateTime.compare(reloaded.last_heartbeat_at, original_heartbeat) == :gt
  end

  test "touch is throttled", %{user: user, agent: agent} do
    {run, home} = seed_running_heartbeat_run(user, agent)
    RunLiveness.reset_throttle(home.id)

    assert :ok = RunLiveness.touch(home.id)
    t1 = reload(run).last_heartbeat_at

    assert :ok = RunLiveness.touch(home.id)
    t2 = reload(run).last_heartbeat_at

    assert DateTime.compare(t2, t1) == :eq
  end

  test "reset_throttle allows immediate re-touch", %{user: user, agent: agent} do
    {run, home} = seed_running_heartbeat_run(user, agent)
    RunLiveness.reset_throttle(home.id)

    assert :ok = RunLiveness.touch(home.id)
    t1 = reload(run).last_heartbeat_at

    assert :ok = RunLiveness.touch(home.id)
    assert DateTime.compare(reload(run).last_heartbeat_at, t1) == :eq

    RunLiveness.reset_throttle(home.id)
    Process.sleep(1100)

    assert :ok = RunLiveness.touch(home.id)
    assert DateTime.compare(reload(run).last_heartbeat_at, t1) == :gt
  end

  test "touch ignores non-running runs", %{user: user, agent: agent} do
    {run, home} =
      seed_agent_run(user, agent, fn run ->
        {:ok, started} = Magus.Agents.start_agent_run(run, authorize?: false)
        {:ok, completed} = Magus.Agents.complete_agent_run(started, authorize?: false)
        completed
      end)

    RunLiveness.reset_throttle(home.id)

    original_heartbeat = reload(run).last_heartbeat_at

    Process.sleep(1100)

    assert :ok = RunLiveness.touch(home.id)

    assert DateTime.compare(reload(run).last_heartbeat_at, original_heartbeat) == :eq
  end

  test "touch with nil / unknown conversation is :ok" do
    assert :ok = RunLiveness.touch(nil)
    assert :ok = RunLiveness.touch(Ash.UUID.generate())
  end
end
