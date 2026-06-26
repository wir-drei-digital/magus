defmodule Magus.Agents.HeartbeatIntegrationTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents, as: CustomAgents

  setup do
    user = generate(user())

    {:ok, agent} =
      CustomAgents.create_custom_agent(
        %{name: "Monitor", heartbeat_instructions: "Check for errors"},
        actor: user
      )

    %{user: user, agent: agent}
  end

  describe "heartbeat config attributes" do
    test "heartbeat_enabled defaults to false", %{agent: agent} do
      assert agent.heartbeat_enabled == false
    end

    test "heartbeat_default_interval_minutes defaults to 360", %{agent: agent} do
      assert agent.heartbeat_default_interval_minutes == 360
    end

    test "heartbeat_instructions are persisted", %{agent: agent} do
      assert agent.heartbeat_instructions == "Check for errors"
    end

    test "enabling heartbeat updates the attribute", %{agent: agent, user: user} do
      {:ok, updated} =
        CustomAgents.update_custom_agent(agent, %{heartbeat_enabled: true}, actor: user)

      assert updated.heartbeat_enabled == true
    end

    test "disabling heartbeat updates the attribute", %{agent: agent, user: user} do
      {:ok, agent} =
        CustomAgents.update_custom_agent(agent, %{heartbeat_enabled: true}, actor: user)

      {:ok, updated} =
        CustomAgents.update_custom_agent(agent, %{heartbeat_enabled: false}, actor: user)

      assert updated.heartbeat_enabled == false
    end

    test "custom interval is persisted", %{agent: agent, user: user} do
      {:ok, updated} =
        CustomAgents.update_custom_agent(
          agent,
          %{heartbeat_default_interval_minutes: 30},
          actor: user
        )

      assert updated.heartbeat_default_interval_minutes == 30
    end

    test "interval_minutes has a minimum constraint of 5", %{agent: agent, user: user} do
      assert {:error, _} =
               CustomAgents.update_custom_agent(
                 agent,
                 %{heartbeat_default_interval_minutes: 4},
                 actor: user
               )
    end

    test "heartbeat_instructions can be updated", %{agent: agent, user: user} do
      {:ok, updated} =
        CustomAgents.update_custom_agent(
          agent,
          %{heartbeat_instructions: "Check Sentry for new errors"},
          actor: user
        )

      assert updated.heartbeat_instructions == "Check Sentry for new errors"
    end
  end
end
