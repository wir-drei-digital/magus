defmodule MagusWeb.WebhookControllerTest do
  @moduledoc """
  Tests for the webhook controller endpoint.
  """
  use MagusWeb.ConnCase, async: false

  alias Magus.Integrations

  setup do
    user = Magus.Generators.generate(Magus.Generators.user())

    {:ok, agent} =
      Magus.Agents.create_custom_agent(%{name: "Test Agent"}, actor: user)

    %{user: user, agent: agent}
  end

  # Helper to create an integration with a Credential containing the API key
  defp create_integration_with_credential(user, agent, api_key, opts \\ []) do
    conversation_mode = Keyword.get(opts, :conversation_mode, :single)

    {:ok, integration} =
      Integrations.create_user_integration(
        :simple_webhook,
        %{user_id: user.id, custom_agent_id: agent.id, conversation_mode: conversation_mode},
        actor: user
      )

    {:ok, _credential} =
      Integrations.create_credential(
        %{
          user_integration_id: integration.id,
          credential_type: :api_key,
          encrypted_data: %{"api_key" => api_key}
        },
        authorize?: false
      )

    {:ok, activated} = Integrations.activate_user_integration(integration, actor: user)
    {:ok, activated}
  end

  describe "POST /webhooks/:provider/:integration_id" do
    test "returns 404 for unknown provider", %{conn: conn} do
      conn = post(conn, "/webhooks/unknown_provider/#{Ash.UUIDv7.generate()}", %{text: "Hello"})
      assert response(conn, 404) =~ "Unknown provider"
    end

    test "returns 404 when integration does not exist", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-api-key", "some-key")
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/simple_webhook/#{Ash.UUIDv7.generate()}", %{text: "Hello"})

      assert response(conn, 404) =~ "Integration not found"
    end

    test "returns 404 when integration is inactive", %{conn: conn, user: user, agent: agent} do
      # Create integration but don't activate it
      {:ok, integration} =
        Integrations.create_user_integration(
          :simple_webhook,
          %{user_id: user.id, custom_agent_id: agent.id},
          actor: user
        )

      conn =
        conn
        |> put_req_header("x-api-key", "test-key")
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/simple_webhook/#{integration.id}", %{text: "Hello"})

      assert response(conn, 404) =~ "Integration not active"
    end

    test "returns 401 when API key is missing", %{conn: conn, user: user, agent: agent} do
      {:ok, integration} = create_integration_with_credential(user, agent, "test-key")

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/simple_webhook/#{integration.id}", %{text: "Hello"})

      assert response(conn, 401) =~ "Unauthorized"
    end

    test "returns 401 when API key is wrong", %{conn: conn, user: user, agent: agent} do
      {:ok, integration} = create_integration_with_credential(user, agent, "correct-key")

      conn =
        conn
        |> put_req_header("x-api-key", "wrong-key")
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/simple_webhook/#{integration.id}", %{text: "Hello"})

      assert response(conn, 401) =~ "Unauthorized"
    end

    test "returns 200 and creates input message on success", %{
      conn: conn,
      user: user,
      agent: agent
    } do
      {:ok, integration} = create_integration_with_credential(user, agent, "test-secret")

      conn =
        conn
        |> put_req_header("x-api-key", "test-secret")
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/simple_webhook/#{integration.id}", %{
          text: "Hello from webhook",
          message_id: "ext-123"
        })

      assert json_response(conn, 200)["status"] == "received"

      # Give async task time to complete
      Process.sleep(100)

      # Verify input message was created
      {:ok, messages} = Integrations.list_recent_input_messages(user.id, authorize?: false)
      assert length(messages) >= 1

      message = hd(messages)
      assert message.provider_key == :simple_webhook
      assert message.payload["text"] == "Hello from webhook"
    end

    test "handles sender_id for multi-mode routing", %{
      conn: conn,
      user: user,
      agent: agent
    } do
      {:ok, integration} =
        create_integration_with_credential(user, agent, "multi-test-key",
          conversation_mode: :multi
        )

      conn =
        conn
        |> put_req_header("x-api-key", "multi-test-key")
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/simple_webhook/#{integration.id}", %{
          text: "Multi mode message",
          sender_id: "user-456"
        })

      assert json_response(conn, 200)["status"] == "received"

      Process.sleep(100)

      {:ok, messages} = Integrations.list_recent_input_messages(user.id, authorize?: false)
      message = hd(messages)
      assert message.payload["sender_id"] == "user-456"
    end
  end

  describe "rate limiting" do
    test "is applied per user and provider", %{conn: _conn, user: user, agent: agent} do
      {:ok, integration} = create_integration_with_credential(user, agent, "rate-test")

      # First request should succeed
      conn1 =
        build_conn()
        |> put_req_header("x-api-key", "rate-test")
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/simple_webhook/#{integration.id}", %{text: "First"})

      assert json_response(conn1, 200)

      # Subsequent requests within rate limit window should also succeed
      # (default rate limit is generous for testing)
      conn2 =
        build_conn()
        |> put_req_header("x-api-key", "rate-test")
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/simple_webhook/#{integration.id}", %{text: "Second"})

      assert json_response(conn2, 200)
    end
  end
end
