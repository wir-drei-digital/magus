defmodule Magus.Agents.Tools.Integrations.HttpRequestTest do
  use Magus.DataCase, async: true

  alias Magus.Agents.Tools.Integrations.HttpRequest
  alias Magus.Generators

  setup do
    user = Generators.generate(Generators.user())
    agent = Generators.custom_agent(user)

    {:ok, integration} =
      Magus.Integrations.create_user_integration(
        :custom_api,
        %{
          user_id: user.id,
          custom_agent_id: agent.id,
          config: %{
            "name" => "Test API",
            "base_url" => "http://test-api.example.com",
            "auth_method" => "bearer",
            "default_headers" => %{"Accept" => "application/json"},
            "endpoints" => []
          }
        },
        authorize?: false
      )

    {:ok, _credential} =
      Magus.Integrations.create_credential(
        %{
          user_integration_id: integration.id,
          credential_type: :api_key,
          encrypted_data: %{"token" => "test-bearer-token"}
        },
        authorize?: false
      )

    {:ok, integration} =
      Magus.Integrations.activate_user_integration(integration, authorize?: false)

    context = %{
      user_id: user.id,
      conversation_id: "test-conv",
      __conversation_id__: "test-conv"
    }

    %{integration: integration, user: user, agent: agent, context: context}
  end

  describe "display_name/0" do
    test "returns display string" do
      assert HttpRequest.display_name() == "Making API request..."
    end
  end

  describe "summarize_output/1" do
    test "summarizes successful response" do
      assert HttpRequest.summarize_output(%{status: 200, body: %{}}) == "HTTP 200 OK"
    end

    test "summarizes client error" do
      assert HttpRequest.summarize_output(%{status: 404, error: "client_error"}) ==
               "HTTP 404 client_error"
    end

    test "summarizes server error" do
      assert HttpRequest.summarize_output(%{status: 500, error: "server_error"}) ==
               "HTTP 500 server_error"
    end

    test "summarizes tool-level error" do
      assert HttpRequest.summarize_output(%{error: "Something broke"}) ==
               "Error: Something broke"
    end

    test "fallback" do
      assert HttpRequest.summarize_output(%{}) == "Request completed"
    end
  end

  describe "run/2 - GET with bearer auth" do
    test "sends GET with Authorization header", %{integration: integration, context: context} do
      Req.Test.stub(HttpRequest, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/issues"

        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer test-bearer-token"]

        accept = Plug.Conn.get_req_header(conn, "accept")
        assert accept == ["application/json"]

        Req.Test.json(conn, %{"issues" => []})
      end)

      params = %{
        "integration_id" => integration.id,
        "method" => "GET",
        "path" => "/api/issues"
      }

      assert {:ok, result} = HttpRequest.run(params, context)
      assert result.status == 200
      assert result.body["issues"] == []
    end
  end

  describe "run/2 - POST with JSON body" do
    test "sends POST with JSON body", %{integration: integration, context: context} do
      Req.Test.stub(HttpRequest, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/issues"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["title"] == "New issue"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{"id" => 1, "title" => "New issue"}))
      end)

      params = %{
        "integration_id" => integration.id,
        "method" => "POST",
        "path" => "/api/issues",
        "body" => %{"title" => "New issue"}
      }

      assert {:ok, result} = HttpRequest.run(params, context)
      assert result.status == 201
      assert result.body["id"] == 1
    end
  end

  describe "run/2 - missing credentials" do
    test "returns error when credentials not found", %{
      user: user,
      agent: agent,
      context: context
    } do
      {:ok, integration_no_creds} =
        Magus.Integrations.create_user_integration(
          :custom_api,
          %{
            user_id: user.id,
            custom_agent_id: agent.id,
            config: %{
              "name" => "No Creds API",
              "base_url" => "http://no-creds.example.com",
              "auth_method" => "bearer",
              "default_headers" => %{},
              "endpoints" => []
            }
          },
          authorize?: false
        )

      {:ok, integration_no_creds} =
        Magus.Integrations.activate_user_integration(integration_no_creds, authorize?: false)

      params = %{
        "integration_id" => integration_no_creds.id,
        "method" => "GET",
        "path" => "/test"
      }

      assert {:ok, %{error: error}} = HttpRequest.run(params, context)
      assert error =~ "credentials"
    end
  end

  describe "run/2 - 4xx response handling" do
    test "returns client_error for 4xx", %{integration: integration, context: context} do
      Req.Test.stub(HttpRequest, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"message" => "Not found"}))
      end)

      params = %{
        "integration_id" => integration.id,
        "method" => "GET",
        "path" => "/api/missing"
      }

      assert {:ok, result} = HttpRequest.run(params, context)
      assert result.status == 404
      assert result.error == "client_error"
      assert result.body["message"] == "Not found"
    end
  end

  describe "run/2 - large response truncation" do
    test "truncates response body over 8KB", %{integration: integration, context: context} do
      large_body = String.duplicate("x", 10_000)

      Req.Test.stub(HttpRequest, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.resp(200, large_body)
      end)

      params = %{
        "integration_id" => integration.id,
        "method" => "GET",
        "path" => "/api/large"
      }

      assert {:ok, result} = HttpRequest.run(params, context)
      assert result.status == 200
      assert is_binary(result.body)
      assert String.contains?(result.body, "[truncated]")
    end
  end

  describe "run/2 - custom headers merged with defaults" do
    test "merges custom headers with defaults", %{integration: integration, context: context} do
      Req.Test.stub(HttpRequest, fn conn ->
        assert Plug.Conn.get_req_header(conn, "accept") == ["application/json"]
        assert Plug.Conn.get_req_header(conn, "x-custom") == ["custom-value"]

        Req.Test.json(conn, %{"ok" => true})
      end)

      params = %{
        "integration_id" => integration.id,
        "method" => "GET",
        "path" => "/api/data",
        "headers" => %{"X-Custom" => "custom-value"}
      }

      assert {:ok, result} = HttpRequest.run(params, context)
      assert result.status == 200
    end
  end

  describe "run/2 - ownership verification" do
    test "rejects request from wrong user", %{integration: integration} do
      other_user = Generators.generate(Generators.user())

      params = %{
        "integration_id" => integration.id,
        "method" => "GET",
        "path" => "/test"
      }

      context = %{
        user_id: other_user.id,
        conversation_id: "test-conv",
        __conversation_id__: "test-conv"
      }

      assert {:ok, %{error: error}} = HttpRequest.run(params, context)
      assert error =~ "not authorized"
    end
  end

  describe "run/2 - auth_method: none" do
    test "makes request without auth header", %{user: user, agent: agent, context: context} do
      {:ok, integration_no_auth} =
        Magus.Integrations.create_user_integration(
          :custom_api,
          %{
            user_id: user.id,
            custom_agent_id: agent.id,
            config: %{
              "name" => "Public API",
              "base_url" => "http://public.example.com",
              "auth_method" => "none",
              "default_headers" => %{},
              "endpoints" => []
            }
          },
          authorize?: false
        )

      {:ok, integration_no_auth} =
        Magus.Integrations.activate_user_integration(integration_no_auth, authorize?: false)

      Req.Test.stub(HttpRequest, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == []

        Req.Test.json(conn, %{"public" => true})
      end)

      params = %{
        "integration_id" => integration_no_auth.id,
        "method" => "GET",
        "path" => "/public"
      }

      assert {:ok, result} = HttpRequest.run(params, context)
      assert result.status == 200
      assert result.body["public"] == true
    end
  end
end
