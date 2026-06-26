defmodule Magus.Agents.CustomAgentAutonomyTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents, as: CustomAgents

  setup do
    user = generate(user())
    %{user: user}
  end

  describe "budget fields" do
    test "creates agent with budget fields", %{user: user} do
      {:ok, agent} =
        CustomAgents.create_custom_agent(
          %{name: "Dev", is_paused: false, max_daily_runs: 10, max_tokens_per_run: 50_000},
          actor: user
        )

      assert agent.is_paused == false
      assert agent.max_daily_runs == 10
      assert agent.max_tokens_per_run == 50_000
    end

    test "defaults: is_paused false, limits nil", %{user: user} do
      {:ok, agent} = CustomAgents.create_custom_agent(%{name: "Agent"}, actor: user)

      assert agent.is_paused == false
      assert is_nil(agent.max_daily_runs)
      assert is_nil(agent.max_tokens_per_run)
    end

    test "can pause and unpause", %{user: user} do
      {:ok, agent} = CustomAgents.create_custom_agent(%{name: "Agent"}, actor: user)
      {:ok, paused} = CustomAgents.update_custom_agent(agent, %{is_paused: true}, actor: user)
      assert paused.is_paused == true

      {:ok, resumed} = CustomAgents.update_custom_agent(paused, %{is_paused: false}, actor: user)
      assert resumed.is_paused == false
    end
  end

  describe "heartbeat fields" do
    test "creates agent with heartbeat config", %{user: user} do
      {:ok, agent} =
        CustomAgents.create_custom_agent(
          %{
            name: "Monitor",
            heartbeat_enabled: true,
            heartbeat_instructions: "Check Sentry for new errors",
            heartbeat_default_interval_minutes: 30
          },
          actor: user
        )

      assert agent.heartbeat_enabled == true
      assert agent.heartbeat_instructions == "Check Sentry for new errors"
      assert agent.heartbeat_default_interval_minutes == 30
    end

    test "defaults: disabled, nil instructions, 360 min interval", %{user: user} do
      {:ok, agent} = CustomAgents.create_custom_agent(%{name: "Agent"}, actor: user)

      assert agent.heartbeat_enabled == false
      assert is_nil(agent.heartbeat_instructions)
      assert agent.heartbeat_default_interval_minutes == 360
    end
  end
end
