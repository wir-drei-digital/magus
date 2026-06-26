defmodule Magus.Agents.Tools.Integrations.ConfigureApiIntegrationTest do
  use Magus.DataCase, async: true

  alias Magus.Agents.Tools.Integrations.ConfigureApiIntegration
  import Magus.Generators

  setup do
    user = generate(user())
    agent = custom_agent(user)

    context = %{
      user_id: user.id,
      conversation_id: "test-conv",
      __conversation_id__: "test-conv"
    }

    %{user: user, agent: agent, context: context}
  end

  describe "display_name/0" do
    test "returns display string" do
      assert ConfigureApiIntegration.display_name() == "Configuring API integration..."
    end
  end

  describe "summarize_output/1" do
    test "summarizes successful configuration with endpoint count" do
      assert ConfigureApiIntegration.summarize_output(%{name: "Jira", endpoints_count: 3}) ==
               "Configured Jira (3 endpoints)"
    end

    test "summarizes error" do
      assert ConfigureApiIntegration.summarize_output(%{error: "Agent not found"}) ==
               "Error: Agent not found"
    end

    test "fallback for unexpected output" do
      assert ConfigureApiIntegration.summarize_output(%{}) == "Completed"
    end
  end

  describe "run/2 - create integration" do
    test "creates a custom_api integration with correct config", %{
      agent: agent,
      context: context
    } do
      params = %{
        "custom_agent_id" => agent.id,
        "name" => "GitHub",
        "base_url" => "https://api.github.com",
        "auth_method" => "bearer",
        "auth_header_name" => nil,
        "default_headers" => %{"Accept" => "application/vnd.github+json"},
        "endpoints" => [%{"path" => "/repos", "method" => "GET", "description" => "List repos"}]
      }

      assert {:ok, result} = ConfigureApiIntegration.run(params, context)
      assert result.name == "GitHub"
      assert result.endpoints_count == 1
      assert result.status == "pending"
      assert result.integration_id != nil

      assert result.message =~
               "Please add your API credentials in the agent settings to activate it."

      # Verify integration was persisted with correct config
      {:ok, [integration]} =
        Magus.Integrations.list_by_agent_and_provider(agent.id, :custom_api, authorize?: false)

      assert integration.config["name"] == "GitHub"
      assert integration.config["base_url"] == "https://api.github.com"
      assert integration.config["auth_method"] == "bearer"
      assert integration.config["default_headers"]["Accept"] == "application/vnd.github+json"
      assert length(integration.config["endpoints"]) == 1
    end
  end

  describe "run/2 - update existing integration" do
    test "updates existing integration with same name instead of creating duplicate", %{
      agent: agent,
      context: context
    } do
      # Create initial integration
      {:ok, _initial} =
        Magus.Integrations.create_user_integration(
          :custom_api,
          %{
            user_id: context.user_id,
            custom_agent_id: agent.id,
            config: %{
              "name" => "Jira",
              "base_url" => "https://old.atlassian.net",
              "auth_method" => "basic",
              "default_headers" => %{},
              "endpoints" => []
            }
          },
          authorize?: false
        )

      # Run the tool with updated config for same name
      params = %{
        "custom_agent_id" => agent.id,
        "name" => "Jira",
        "base_url" => "https://new.atlassian.net",
        "auth_method" => "bearer",
        "auth_header_name" => nil,
        "default_headers" => %{},
        "endpoints" => [%{"path" => "/issue", "method" => "POST"}]
      }

      assert {:ok, result} = ConfigureApiIntegration.run(params, context)
      assert result.name == "Jira"
      assert result.endpoints_count == 1

      # Confirm only one integration exists (no duplicate)
      {:ok, integrations} =
        Magus.Integrations.list_by_agent_and_provider(agent.id, :custom_api, authorize?: false)

      assert length(integrations) == 1
      [updated] = integrations
      assert updated.config["base_url"] == "https://new.atlassian.net"
      assert updated.config["auth_method"] == "bearer"
    end
  end

  describe "run/2 - authorization" do
    test "rejects access when agent belongs to a different user", %{
      agent: agent,
      context: _context
    } do
      other_user = generate(user())

      other_context = %{
        user_id: other_user.id,
        conversation_id: "test-conv",
        __conversation_id__: "test-conv"
      }

      params = %{
        "custom_agent_id" => agent.id,
        "name" => "Some API",
        "base_url" => "https://api.example.com",
        "auth_method" => "none",
        "auth_header_name" => nil,
        "default_headers" => %{},
        "endpoints" => []
      }

      assert {:ok, %{error: error}} = ConfigureApiIntegration.run(params, other_context)
      assert error =~ "Unauthorized"
    end

    test "returns error when agent does not exist", %{context: context} do
      params = %{
        "custom_agent_id" => Ecto.UUID.generate(),
        "name" => "Some API",
        "base_url" => "https://api.example.com",
        "auth_method" => "none",
        "auth_header_name" => nil,
        "default_headers" => %{},
        "endpoints" => []
      }

      assert {:ok, %{error: error}} = ConfigureApiIntegration.run(params, context)
      assert error =~ "not found"
    end
  end
end
