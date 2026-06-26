defmodule MagusWeb.WebhookControllerIngestionTest do
  @moduledoc """
  Tests for data source provider webhook ingestion branching.

  When a provider implements DataSourceBehaviour (parse_ingestion_payload/2),
  the webhook controller routes to ProcessIngestion instead of ProcessWebhook.
  """
  use MagusWeb.ConnCase, async: false

  alias Magus.Integrations

  setup do
    user = Magus.Generators.generate(Magus.Generators.user())

    {:ok, agent} =
      Magus.Agents.create_custom_agent(%{name: "Logger Agent"}, actor: user)

    {:ok, integration} =
      Integrations.create_user_integration(
        :log_source,
        %{
          user_id: user.id,
          custom_agent_id: agent.id,
          config: %{
            "error_threshold" => 5,
            "window_minutes" => 5,
            "webhook_secret" => "test-secret"
          }
        },
        actor: user
      )

    {:ok, integration} = Integrations.activate_user_integration(integration, actor: user)

    %{user: user, agent: agent, integration: integration}
  end

  describe "POST /webhooks/log_source/:integration_id" do
    test "ingests a single log entry", %{conn: conn, integration: integration} do
      payload = %{
        "message" => "Application started",
        "level" => "info",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-api-key", "test-secret")
        |> post("/webhooks/log_source/#{integration.id}", payload)

      assert json_response(conn, 200)["status"] == "ok"
      assert json_response(conn, 200)["ingested"] == 1
    end

    test "ingests batch of log entries", %{conn: conn, integration: integration} do
      payload = %{
        "entries" => [
          %{
            "message" => "Request 1",
            "level" => "info",
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          },
          %{
            "message" => "Error 1",
            "level" => "error",
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        ]
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-api-key", "test-secret")
        |> post("/webhooks/log_source/#{integration.id}", payload)

      assert json_response(conn, 200)["status"] == "ok"
      assert json_response(conn, 200)["ingested"] == 2
    end

    test "returns 404 for unknown integration", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-api-key", "test-secret")
        |> post("/webhooks/log_source/#{Ash.UUIDv7.generate()}", %{"message" => "test"})

      assert response(conn, 404)
    end

    test "deduplicates entries with same content", %{conn: conn, integration: integration} do
      payload = %{
        "message" => "Duplicate message",
        "level" => "info",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      # First request
      conn1 =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-api-key", "test-secret")
        |> post("/webhooks/log_source/#{integration.id}", payload)

      assert json_response(conn1, 200)["ingested"] == 1

      # Second request with same content should skip the duplicate
      conn2 =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-api-key", "test-secret")
        |> post("/webhooks/log_source/#{integration.id}", payload)

      assert json_response(conn2, 200)["ingested"] == 0
    end

    test "returns 400 for invalid payload", %{conn: conn, integration: integration} do
      payload = %{"not_a_message" => "missing required fields"}

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-api-key", "test-secret")
        |> post("/webhooks/log_source/#{integration.id}", payload)

      assert json_response(conn, 400)["error"] == "ingestion_failed"
    end
  end
end
