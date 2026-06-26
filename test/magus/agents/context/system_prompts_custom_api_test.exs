defmodule Magus.Agents.Context.SystemPromptsCustomApiTest do
  @moduledoc """
  Tests for custom API integration injection into system prompts.

  Verifies that active :custom_api integrations are documented in the
  agent's system prompt so the LLM knows how to call them via http_request.
  """
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Agents.Context.SystemPrompts

  describe "build/1 with custom_api integrations" do
    test "includes Available APIs section when agent has active custom_api integration with credentials" do
      user = generate(user())
      agent = custom_agent(user)

      config = %{
        "name" => "My Billing API",
        "base_url" => "https://api.example.com",
        "auth_method" => "bearer",
        "endpoints" => [
          %{
            "method" => "POST",
            "path" => "/invoices",
            "description" => "Create a new invoice",
            "body_template" => ~s({"amount": 100}),
            "response_description" => "Returns the created invoice"
          },
          %{
            "method" => "GET",
            "path" => "/invoices/{id}",
            "description" => "Fetch an invoice by ID"
          }
        ]
      }

      {:ok, integration} =
        Magus.Integrations.create_user_integration(
          :custom_api,
          %{
            user_id: user.id,
            custom_agent_id: agent.id,
            config: config
          },
          authorize?: false
        )

      {:ok, _credential} =
        Magus.Integrations.create_credential(
          %{
            credential_type: :api_key,
            encrypted_data: %{"api_key" => "secret-key"},
            user_integration_id: integration.id
          },
          authorize?: false
        )

      {:ok, _} = Magus.Integrations.activate_user_integration(integration, authorize?: false)

      prompt = SystemPrompts.build(custom_agent: agent, user: user)

      assert String.contains?(prompt, "Available APIs")
      assert String.contains?(prompt, "My Billing API")
      assert String.contains?(prompt, "POST /invoices")
      assert String.contains?(prompt, "GET /invoices/{id}")
      assert String.contains?(prompt, "http_request")
      assert String.contains?(prompt, integration.id)
    end

    test "excludes Available APIs section when agent has no custom_api integrations" do
      user = generate(user())
      agent = custom_agent(user)

      prompt = SystemPrompts.build(custom_agent: agent, user: user)

      refute String.contains?(prompt, "Available APIs")
    end

    test "shows NOT CONFIGURED warning for integrations without credentials" do
      user = generate(user())
      agent = custom_agent(user)

      config = %{
        "name" => "Unconfigured API",
        "base_url" => "https://api.example.com",
        "auth_method" => "bearer",
        "endpoints" => [
          %{
            "method" => "GET",
            "path" => "/data",
            "description" => "Fetch data"
          }
        ]
      }

      {:ok, integration} =
        Magus.Integrations.create_user_integration(
          :custom_api,
          %{
            user_id: user.id,
            custom_agent_id: agent.id,
            config: config
          },
          authorize?: false
        )

      {:ok, _} = Magus.Integrations.activate_user_integration(integration, authorize?: false)

      prompt = SystemPrompts.build(custom_agent: agent, user: user)

      assert String.contains?(prompt, "NOT CONFIGURED")
    end

    test "excludes Available APIs section when all custom_api integrations are inactive" do
      user = generate(user())
      agent = custom_agent(user)

      config = %{
        "name" => "Pending API",
        "base_url" => "https://api.example.com",
        "auth_method" => "bearer",
        "endpoints" => []
      }

      # Create but do not activate
      {:ok, _integration} =
        Magus.Integrations.create_user_integration(
          :custom_api,
          %{
            user_id: user.id,
            custom_agent_id: agent.id,
            config: config
          },
          authorize?: false
        )

      prompt = SystemPrompts.build(custom_agent: agent, user: user)

      refute String.contains?(prompt, "Available APIs")
    end

    test "excludes Available APIs section when custom_agent is nil" do
      user = generate(user())

      prompt = SystemPrompts.build(user: user)

      refute String.contains?(prompt, "Available APIs")
    end
  end
end
