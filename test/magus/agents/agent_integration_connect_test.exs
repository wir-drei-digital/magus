defmodule Magus.Agents.AgentIntegrationConnectTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Agents.CustomAgent

  setup do
    user = generate(user())
    agent = custom_agent(user)
    %{user: user, agent: agent}
  end

  defp run_action(action, params, user) do
    CustomAgent
    |> Ash.ActionInput.for_action(action, params, actor: user)
    |> Ash.run_action()
  end

  describe "available_integration_providers" do
    test "lists connectable providers and excludes knowledge sources", %{
      user: user,
      agent: agent
    } do
      assert {:ok, providers} =
               run_action(:available_integration_providers, %{agent_id: agent.id}, user)

      keys = Enum.map(providers, & &1.key)
      assert "rss_source" in keys
      assert "api" in keys
      assert "telegram" in keys
      refute "google_drive_knowledge" in keys
      refute "notion_knowledge" in keys
    end
  end

  describe "connect_agent_integration" do
    test "connects a no-auth provider and activates it", %{user: user, agent: agent} do
      assert {:ok, summary} =
               run_action(
                 :connect_agent_integration,
                 %{agent_id: agent.id, provider_key: "rss_source"},
                 user
               )

      assert summary.provider_key == "rss_source"
      assert summary.status == "active"
      assert is_binary(summary.id)
    end

    test "surfaces the one-time API key for the api provider", %{user: user, agent: agent} do
      assert {:ok, summary} =
               run_action(
                 :connect_agent_integration,
                 %{agent_id: agent.id, provider_key: "api"},
                 user
               )

      assert summary.status == "active"
      assert is_binary(summary.api_key)
      assert String.starts_with?(summary.api_key, "magus_sk_")
    end

    test "rejects an unknown provider", %{user: user, agent: agent} do
      assert {:error, _} =
               run_action(
                 :connect_agent_integration,
                 %{agent_id: agent.id, provider_key: "dropbox"},
                 user
               )
    end

    test "log_source connect persists the generated webhook secret to config", %{
      user: user,
      agent: agent
    } do
      assert {:ok, %{status: "active"}} =
               run_action(
                 :connect_agent_integration,
                 %{agent_id: agent.id, provider_key: "log_source"},
                 user
               )

      # The on_credentials_saved hook must persist the secret itself (the reactor
      # discards its return value); otherwise inbound webhooks can't authenticate.
      assert [integration] = Magus.Integrations.list_agent_integrations!(agent.id, actor: user)
      assert is_binary(integration.config["webhook_secret"])
    end
  end
end
