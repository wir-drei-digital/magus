defmodule Magus.Agents.Tools.Integrations.CustomApiIntegrationTest do
  @moduledoc "Integration test for the full custom API pipeline."
  use Magus.DataCase, async: true

  alias Magus.Agents.Tools.Integrations.{ConfigureApiIntegration, HttpRequest}
  alias Magus.Agents.Context.SystemPrompts

  import Magus.Generators

  setup do
    user = generate(user())
    agent = custom_agent(user, %{name: "API Agent", instructions: "Use APIs."})
    context = %{user_id: user.id, conversation_id: "test-conv", __conversation_id__: "test-conv"}
    %{user: user, agent: agent, context: context}
  end

  test "full pipeline: configure → add credentials → system prompt → http_request", %{
    user: user,
    agent: agent,
    context: context
  } do
    # Step 1: Agent configures the integration via tool
    {:ok, config_result} =
      ConfigureApiIntegration.run(
        %{
          "custom_agent_id" => agent.id,
          "name" => "Test API",
          "base_url" => "http://localhost:4099",
          "auth_method" => "bearer",
          "default_headers" => %{"Accept" => "application/json"},
          "endpoints" => [
            %{
              "key" => "list_items",
              "name" => "List Items",
              "description" => "Get all items",
              "method" => "GET",
              "path" => "/api/items",
              "response_description" => "Array of items with id and name"
            }
          ]
        },
        context
      )

    assert config_result.integration_id
    assert config_result.status == "pending"
    integration_id = config_result.integration_id

    # Step 2: User adds credentials (simulating form submission)
    {:ok, _credential} =
      Magus.Integrations.create_credential(
        %{
          user_integration_id: integration_id,
          credential_type: :api_key,
          encrypted_data: %{"token" => "my-secret-token"}
        },
        authorize?: false
      )

    {:ok, integration} =
      Magus.Integrations.get_user_integration(integration_id, authorize?: false)

    {:ok, _} = Magus.Integrations.activate_user_integration(integration, authorize?: false)

    # Step 3: System prompt includes API docs
    prompt = SystemPrompts.build(custom_agent: agent, user: user)
    assert prompt =~ "Available APIs"
    assert prompt =~ "Test API"
    assert prompt =~ "GET /api/items"
    assert prompt =~ integration_id

    # Step 4: Agent makes an API call via HttpRequest
    Req.Test.stub(HttpRequest, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/items"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer my-secret-token"]
      assert Plug.Conn.get_req_header(conn, "accept") == ["application/json"]

      Req.Test.json(conn, [%{"id" => 1, "name" => "Item 1"}])
    end)

    {:ok, result} =
      HttpRequest.run(
        %{
          "integration_id" => integration_id,
          "method" => "GET",
          "path" => "/api/items"
        },
        context
      )

    assert result.status == 200
    assert [%{"id" => 1, "name" => "Item 1"}] = result.body
  end
end
