defmodule Magus.Agents.AgentSecretTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents, as: CustomAgents

  setup do
    user = generate(user())
    {:ok, agent} = CustomAgents.create_custom_agent(%{name: "Dev Agent"}, actor: user)
    %{user: user, agent: agent}
  end

  describe "create" do
    test "creates a secret with sandbox_env scope", %{agent: agent, user: user} do
      {:ok, secret} =
        CustomAgents.create_agent_secret(
          %{
            custom_agent_id: agent.id,
            key: "GITHUB_TOKEN",
            value: "ghp_abc123",
            scope: :sandbox_env,
            description: "GitHub access token"
          },
          actor: user
        )

      assert secret.key == "GITHUB_TOKEN"
      assert secret.scope == :sandbox_env
      assert secret.description == "GitHub access token"
      assert secret.custom_agent_id == agent.id
    end

    test "encrypts the value (not stored in plaintext)", %{agent: agent, user: user} do
      {:ok, secret} =
        CustomAgents.create_agent_secret(
          %{
            custom_agent_id: agent.id,
            key: "API_KEY",
            value: "secret-value",
            scope: :sandbox_env
          },
          actor: user
        )

      {:ok, found} = CustomAgents.get_agent_secret(secret.id, actor: user)
      assert found.value == "secret-value"
    end

    test "enforces unique key per agent", %{agent: agent, user: user} do
      {:ok, _} =
        CustomAgents.create_agent_secret(
          %{custom_agent_id: agent.id, key: "TOKEN", value: "v1", scope: :sandbox_env},
          actor: user
        )

      assert {:error, _} =
               CustomAgents.create_agent_secret(
                 %{custom_agent_id: agent.id, key: "TOKEN", value: "v2", scope: :sandbox_env},
                 actor: user
               )
    end

    test "defaults scope to sandbox_env", %{agent: agent, user: user} do
      {:ok, secret} =
        CustomAgents.create_agent_secret(
          %{custom_agent_id: agent.id, key: "MY_KEY", value: "val"},
          actor: user
        )

      assert secret.scope == :sandbox_env
    end
  end

  describe "list_for_agent" do
    test "returns only secrets for the given agent", %{agent: agent, user: user} do
      {:ok, _} =
        CustomAgents.create_agent_secret(
          %{custom_agent_id: agent.id, key: "KEY1", value: "v1", scope: :sandbox_env},
          actor: user
        )

      {:ok, secrets} = CustomAgents.list_agent_secrets(agent.id, actor: user)
      assert length(secrets) == 1
      assert hd(secrets).key == "KEY1"
    end

    test "does not return secrets from another agent", %{agent: agent, user: user} do
      {:ok, other_agent} = CustomAgents.create_custom_agent(%{name: "Other Agent"}, actor: user)

      {:ok, _} =
        CustomAgents.create_agent_secret(
          %{custom_agent_id: agent.id, key: "KEY1", value: "v1", scope: :sandbox_env},
          actor: user
        )

      {:ok, secrets} = CustomAgents.list_agent_secrets(other_agent.id, actor: user)
      assert secrets == []
    end
  end

  describe "sandbox_env_for_agent" do
    test "returns only sandbox_env scoped secrets", %{agent: agent, user: user} do
      {:ok, _} =
        CustomAgents.create_agent_secret(
          %{custom_agent_id: agent.id, key: "GH_TOKEN", value: "ghp_123", scope: :sandbox_env},
          actor: user
        )

      {:ok, _} =
        CustomAgents.create_agent_secret(
          %{custom_agent_id: agent.id, key: "INTERNAL", value: "xyz", scope: :tool_config},
          actor: user
        )

      {:ok, secrets} = CustomAgents.sandbox_env_for_agent(agent.id, actor: user)
      assert length(secrets) == 1
      assert hd(secrets).key == "GH_TOKEN"
    end
  end

  describe "sandbox_env_map_for_agent" do
    test "returns sandbox_env secrets as a key-value map", %{agent: agent, user: user} do
      {:ok, _} =
        CustomAgents.create_agent_secret(
          %{custom_agent_id: agent.id, key: "GH_TOKEN", value: "ghp_123", scope: :sandbox_env},
          actor: user
        )

      {:ok, _} =
        CustomAgents.create_agent_secret(
          %{custom_agent_id: agent.id, key: "INTERNAL", value: "xyz", scope: :tool_config},
          actor: user
        )

      {:ok, env_map} = CustomAgents.sandbox_env_map_for_agent(agent.id, actor: user)
      assert env_map == %{"GH_TOKEN" => "ghp_123"}
    end

    test "returns empty map when no sandbox_env secrets exist", %{agent: agent, user: user} do
      {:ok, env_map} = CustomAgents.sandbox_env_map_for_agent(agent.id, actor: user)
      assert env_map == %{}
    end
  end

  describe "update" do
    test "updates value and description", %{agent: agent, user: user} do
      {:ok, secret} =
        CustomAgents.create_agent_secret(
          %{custom_agent_id: agent.id, key: "MY_TOKEN", value: "old-value", scope: :sandbox_env},
          actor: user
        )

      {:ok, updated} =
        CustomAgents.update_agent_secret(secret, %{value: "new-value", description: "updated"},
          actor: user
        )

      assert updated.value == "new-value"
      assert updated.description == "updated"
    end
  end

  describe "destroy" do
    test "destroys a secret", %{agent: agent, user: user} do
      {:ok, secret} =
        CustomAgents.create_agent_secret(
          %{custom_agent_id: agent.id, key: "TEMP_KEY", value: "val", scope: :sandbox_env},
          actor: user
        )

      assert :ok = CustomAgents.destroy_agent_secret(secret, actor: user)
      assert {:error, _} = CustomAgents.get_agent_secret(secret.id, actor: user)
    end
  end

  describe "authorization" do
    test "cannot access secrets belonging to another user's agent", %{agent: agent, user: user} do
      other_user = generate(user())

      {:ok, secret} =
        CustomAgents.create_agent_secret(
          %{custom_agent_id: agent.id, key: "SECRET", value: "hidden", scope: :sandbox_env},
          actor: user
        )

      assert {:error, _} = CustomAgents.get_agent_secret(secret.id, actor: other_user)
    end

    test "AI actor cannot read secrets through the public resource action", %{
      agent: agent,
      user: user
    } do
      {:ok, secret} =
        CustomAgents.create_agent_secret(
          %{custom_agent_id: agent.id, key: "SECRET", value: "hidden", scope: :sandbox_env},
          actor: user
        )

      assert {:error, _} =
               CustomAgents.get_agent_secret(secret.id, actor: %Magus.Agents.Support.AiAgent{})
    end
  end
end
