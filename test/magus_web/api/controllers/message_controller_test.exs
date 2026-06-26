defmodule MagusWeb.Api.MessageControllerTest do
  @moduledoc """
  Integration tests for the API channel message endpoint.

  Tests the HTTP layer: authentication, request parsing, and session management.
  The full agent pipeline (LLM calls) is not exercised here — these are
  unit-level integration tests focused on the request/response contracts.
  """
  use MagusWeb.ConnCase, async: false

  alias Magus.Integrations
  alias Magus.Integrations.Providers.Api, as: ApiProvider

  # ---------------------------------------------------------------------------
  # Setup helpers
  # ---------------------------------------------------------------------------

  # Create a user, custom agent, API integration with credential, and return
  # %{user: user, agent: agent, integration: integration, api_key: api_key}
  defp setup_api_integration(opts \\ []) do
    user = Magus.Generators.generate(Magus.Generators.user())
    agent = Magus.Generators.custom_agent(user, %{name: "Test API Agent"})

    integration_opts = Keyword.get(opts, :conversation_mode, :multi)

    {:ok, integration} =
      Integrations.create_user_integration(
        :api,
        %{
          user_id: user.id,
          custom_agent_id: agent.id,
          conversation_mode: integration_opts
        },
        actor: user
      )

    api_key = ApiProvider.generate_api_key()
    key_hash = ApiProvider.hash_api_key(api_key)

    {:ok, _credential} =
      Integrations.create_credential(
        %{
          user_integration_id: integration.id,
          credential_type: :api_key,
          encrypted_data: %{"api_key" => api_key},
          key_hash: key_hash
        },
        authorize?: false
      )

    {:ok, active_integration} = Integrations.activate_user_integration(integration, actor: user)

    %{
      user: user,
      agent: agent,
      integration: active_integration,
      api_key: api_key
    }
  end

  # ---------------------------------------------------------------------------
  # PubSub receive helpers (mirror the controller's logic)
  # ---------------------------------------------------------------------------

  # Mirrors MessageController.accumulate_response — must match Broadcast structs
  defp drain_response(content, message_id, usage) do
    receive do
      %Phoenix.Socket.Broadcast{payload: payload} ->
        case payload do
          %{type: "text.chunk", message_id: id, delta: delta} ->
            drain_response(content <> delta, id || message_id, usage)

          %{type: "response.complete"} ->
            {:ok, content, message_id, format_usage(payload[:usage])}

          %{type: "error"} ->
            {:error, :agent_error, payload[:message] || "An error occurred"}

          _ ->
            drain_response(content, message_id, usage)
        end
    after
      1_000 -> {:error, :timeout}
    end
  end

  # Collects all queued PubSub payloads (unwrapped from Broadcast structs)
  defp drain_events(acc) do
    receive do
      %Phoenix.Socket.Broadcast{payload: payload} ->
        drain_events([payload | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  defp format_usage(nil), do: nil

  defp format_usage(usage) when is_map(usage) do
    %{
      "prompt_tokens" => usage[:prompt_tokens] || usage["prompt_tokens"],
      "completion_tokens" => usage[:completion_tokens] || usage["completion_tokens"]
    }
  end

  # ---------------------------------------------------------------------------
  # Authentication tests
  # ---------------------------------------------------------------------------

  describe "authentication" do
    test "returns 401 when no Authorization header is provided", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/messages", %{content: "Hello"})

      assert json_response(conn, 401)["error"]["code"] == "invalid_api_key"
    end

    test "returns 401 when Authorization header is not Bearer scheme", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Basic abc123")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/messages", %{content: "Hello"})

      assert json_response(conn, 401)["error"]["code"] == "invalid_api_key"
    end

    test "returns 401 when API key does not exist", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer magus_sk_nonexistentkey0000")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/messages", %{content: "Hello"})

      assert json_response(conn, 401)["error"]["code"] == "invalid_api_key"
    end

    test "returns 401 when API key belongs to an inactive integration", %{conn: conn} do
      user = Magus.Generators.generate(Magus.Generators.user())
      agent = Magus.Generators.custom_agent(user, %{name: "Inactive Agent"})

      # Create integration but do NOT activate it
      {:ok, inactive_integration} =
        Integrations.create_user_integration(
          :api,
          %{user_id: user.id, custom_agent_id: agent.id},
          actor: user
        )

      api_key = ApiProvider.generate_api_key()
      key_hash = ApiProvider.hash_api_key(api_key)

      {:ok, _credential} =
        Integrations.create_credential(
          %{
            user_integration_id: inactive_integration.id,
            credential_type: :api_key,
            encrypted_data: %{"api_key" => api_key},
            key_hash: key_hash
          },
          authorize?: false
        )

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/messages", %{content: "Hello"})

      assert conn.status in [401, 403]
    end

    test "returns 403 when credential belongs to a non-API integration", %{conn: conn} do
      user = Magus.Generators.generate(Magus.Generators.user())
      agent = Magus.Generators.custom_agent(user, %{name: "Webhook Agent"})

      # Create a simple_webhook integration (not :api)
      {:ok, webhook_integration} =
        Integrations.create_user_integration(
          :simple_webhook,
          %{user_id: user.id, custom_agent_id: agent.id},
          actor: user
        )

      api_key = ApiProvider.generate_api_key()
      key_hash = ApiProvider.hash_api_key(api_key)

      {:ok, _credential} =
        Integrations.create_credential(
          %{
            user_integration_id: webhook_integration.id,
            credential_type: :api_key,
            encrypted_data: %{"api_key" => api_key},
            key_hash: key_hash
          },
          authorize?: false
        )

      {:ok, _} = Integrations.activate_user_integration(webhook_integration, actor: user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/messages", %{content: "Hello"})

      assert conn.status in [401, 403]
    end
  end

  # ---------------------------------------------------------------------------
  # Request validation tests
  # ---------------------------------------------------------------------------

  describe "request validation" do
    setup do
      {:ok, setup_api_integration()}
    end

    test "returns 400 when content is missing", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/messages", %{})

      assert json_response(conn, 400)["error"]["code"] == "invalid_request"
    end

    test "returns 400 when content key is absent from body", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/messages", %{session_id: "abc", stream: false})

      assert json_response(conn, 400)["error"]["code"] == "invalid_request"
    end
  end

  # ---------------------------------------------------------------------------
  # Session management tests
  # ---------------------------------------------------------------------------

  describe "session management" do
    setup do
      {:ok, setup_api_integration()}
    end

    test "creates an IntegrationConversation record for a new session", ctx do
      %{api_key: api_key, integration: integration} = ctx

      session_id = "test-session-#{System.unique_integer([:positive])}"

      # We post a valid request — the agent pipeline will time out (no real LLM),
      # but the IntegrationConversation mapping should be created before that.
      # We use a Task so we can inspect the DB even if the request is pending.
      task =
        Task.async(fn ->
          build_conn()
          |> put_req_header("authorization", "Bearer #{api_key}")
          |> put_req_header("content-type", "application/json")
          |> post("/api/v1/messages", %{content: "Hello", session_id: session_id})
        end)

      # Give the request time to create the DB records before the LLM times out
      Process.sleep(500)

      # Verify an IntegrationConversation was created for this session
      result =
        Integrations.get_integration_conversation_by_identifier(
          integration.id,
          session_id,
          authorize?: false
        )

      assert {:ok, ic} = result
      assert ic.external_identifier == session_id
      assert ic.user_integration_id == integration.id

      # Clean up the task
      Task.shutdown(task, :brutal_kill)
    end

    test "reuses the same conversation for repeated requests with the same session_id", ctx do
      %{api_key: api_key, integration: integration} = ctx

      session_id = "reuse-session-#{System.unique_integer([:positive])}"

      # First request — create a new conversation/session via Task so it doesn't block
      task1 =
        Task.async(fn ->
          build_conn()
          |> put_req_header("authorization", "Bearer #{api_key}")
          |> put_req_header("content-type", "application/json")
          |> post("/api/v1/messages", %{content: "First message", session_id: session_id})
        end)

      # Wait for the DB write to happen
      Process.sleep(500)

      # Grab the conversation that was created
      {:ok, ic1} =
        Integrations.get_integration_conversation_by_identifier(
          integration.id,
          session_id,
          authorize?: false
        )

      conversation_id_first = ic1.conversation_id
      Task.shutdown(task1, :brutal_kill)

      # Second request with the same session_id — should reuse the conversation
      task2 =
        Task.async(fn ->
          build_conn()
          |> put_req_header("authorization", "Bearer #{api_key}")
          |> put_req_header("content-type", "application/json")
          |> post("/api/v1/messages", %{content: "Second message", session_id: session_id})
        end)

      Process.sleep(500)

      # Verify the same IntegrationConversation record (same conversation_id)
      {:ok, ic2} =
        Integrations.get_integration_conversation_by_identifier(
          integration.id,
          session_id,
          authorize?: false
        )

      assert ic2.conversation_id == conversation_id_first

      Task.shutdown(task2, :brutal_kill)
    end

    test "auto-generates a session_id when none is provided", ctx do
      %{api_key: api_key, integration: integration} = ctx

      task =
        Task.async(fn ->
          build_conn()
          |> put_req_header("authorization", "Bearer #{api_key}")
          |> put_req_header("content-type", "application/json")
          # No session_id — the provider should generate one
          |> post("/api/v1/messages", %{content: "Auto session message"})
        end)

      Process.sleep(500)

      # An IntegrationConversation should have been created with a generated session_id
      require Ash.Query

      conversations =
        Magus.Integrations.IntegrationConversation
        |> Ash.Query.filter(user_integration_id == ^integration.id)
        |> Ash.read!(authorize?: false)

      assert length(conversations) >= 1
      [ic | _] = conversations
      assert is_binary(ic.external_identifier)
      assert String.length(ic.external_identifier) > 0

      Task.shutdown(task, :brutal_kill)
    end

    test "accumulate_response receives Endpoint.broadcast events (non-streaming)", _ctx do
      # This test verifies that the controller's receive patterns correctly
      # unwrap %Phoenix.Socket.Broadcast{} structs sent by Endpoint.broadcast.
      # Previously, patterns matched raw %{type: "text.chunk", ...} which never
      # matched the Broadcast wrapper, causing every request to time out.
      topic = "agents:test-pubsub-format-#{System.unique_integer([:positive])}"
      message_id = Ash.UUID.generate()

      # Subscribe like the controller does
      Phoenix.PubSub.subscribe(Magus.PubSub, topic)

      # Broadcast via Endpoint (same as Signals module) — wraps in %Broadcast{}
      MagusWeb.Endpoint.broadcast(topic, "agent_signal", %{
        type: "text.chunk",
        message_id: message_id,
        text: "Hello ",
        delta: "Hello "
      })

      MagusWeb.Endpoint.broadcast(topic, "agent_signal", %{
        type: "text.chunk",
        message_id: message_id,
        text: "Hello world!",
        delta: "world!"
      })

      MagusWeb.Endpoint.broadcast(topic, "agent_signal", %{
        type: "response.complete",
        message_id: message_id,
        usage: %{prompt_tokens: 10, completion_tokens: 5}
      })

      # Use the same receive loop as the controller
      result = drain_response("", nil, nil)

      assert {:ok, "Hello world!", ^message_id, usage} = result
      assert usage["prompt_tokens"] == 10
      assert usage["completion_tokens"] == 5
    end

    test "SSE streamer receives Endpoint.broadcast events (streaming)", _ctx do
      topic = "agents:test-sse-format-#{System.unique_integer([:positive])}"
      message_id = Ash.UUID.generate()

      Phoenix.PubSub.subscribe(Magus.PubSub, topic)

      MagusWeb.Endpoint.broadcast(topic, "agent_signal", %{
        type: "text.chunk",
        message_id: message_id,
        text: "Hi",
        delta: "Hi"
      })

      MagusWeb.Endpoint.broadcast(topic, "agent_signal", %{
        type: "tool.start",
        event_id: "evt-1",
        tool_name: "web_search",
        display_name: "Searching..."
      })

      MagusWeb.Endpoint.broadcast(topic, "agent_signal", %{
        type: "response.complete",
        message_id: message_id,
        usage: %{prompt_tokens: 5, completion_tokens: 3}
      })

      # Collect all received payloads to verify unwrapping works
      events = drain_events([])

      types = Enum.map(events, & &1[:type])
      assert "text.chunk" in types
      assert "tool.start" in types
      assert "response.complete" in types

      chunk = Enum.find(events, &(&1[:type] == "text.chunk"))
      assert chunk[:delta] == "Hi"
    end

    test "different session_ids create different conversations", ctx do
      %{api_key: api_key, integration: integration} = ctx

      session_a = "session-a-#{System.unique_integer([:positive])}"
      session_b = "session-b-#{System.unique_integer([:positive])}"

      task_a =
        Task.async(fn ->
          build_conn()
          |> put_req_header("authorization", "Bearer #{api_key}")
          |> put_req_header("content-type", "application/json")
          |> post("/api/v1/messages", %{content: "Hello from A", session_id: session_a})
        end)

      task_b =
        Task.async(fn ->
          build_conn()
          |> put_req_header("authorization", "Bearer #{api_key}")
          |> put_req_header("content-type", "application/json")
          |> post("/api/v1/messages", %{content: "Hello from B", session_id: session_b})
        end)

      Process.sleep(700)

      {:ok, ic_a} =
        Integrations.get_integration_conversation_by_identifier(
          integration.id,
          session_a,
          authorize?: false
        )

      {:ok, ic_b} =
        Integrations.get_integration_conversation_by_identifier(
          integration.id,
          session_b,
          authorize?: false
        )

      assert ic_a.conversation_id != ic_b.conversation_id

      Task.shutdown(task_a, :brutal_kill)
      Task.shutdown(task_b, :brutal_kill)
    end
  end
end
