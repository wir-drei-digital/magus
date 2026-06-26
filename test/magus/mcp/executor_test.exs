defmodule Magus.MCP.ExecutorTest do
  use Magus.ResourceCase, async: false

  alias Magus.MCP
  alias Magus.MCP.Executor
  alias Magus.MCP.MockServer

  @moduletag :mcp_integration

  setup do
    bypass = MockServer.start()
    user = generate(user())

    {:ok, server} =
      MCP.create_server(
        %{
          name: "Svc",
          handle: "svc",
          url: "http://127.0.0.1:#{bypass.port}",
          mcp_path: "/mcp",
          auth_type: :none
        },
        actor: user
      )

    # Warm the Finch connection pool against this Bypass server. The test config
    # uses a deliberately tight `init_timeout_ms: 200`, and the very first dial
    # to a freshly-opened Bypass server can exceed that during cold-start
    # (connection setup), surfacing as `:initialization_timeout`. A throwaway
    # dial primes the pool so the assertions below see the warm-client behavior
    # the real system relies on (clients are reused), making this file
    # deterministic regardless of suite ordering.
    warm_up(server)

    %{user: user, server: server, bypass: bypass}
  end

  defp context(user), do: %{user: user, conversation_id: nil, user_id: user.id}

  defp warm_up(server, attempts \\ 3) do
    case MCP.ClientManager.with_client(server, %{}, fn client -> MCP.Client.list_tools(client) end) do
      {:ok, _} -> :ok
      _ when attempts > 1 -> warm_up(server, attempts - 1)
      _ -> :ok
    end
  end

  test "successful tool call returns {:ok, result-map} with no :error key", %{
    server: server,
    user: user
  } do
    assert {:ok, result} = Executor.call(server, "echo", %{"text" => "hi"}, context(user))
    assert is_map(result)
    refute Map.has_key?(result, :error)
    # The mock returns a canned content payload for every tools/call.
    assert %{"content" => [%{"type" => "text", "text" => "ok"}]} = result
  end

  test "dead/unreachable server returns an actionable soft error, never crashes", %{user: user} do
    {:ok, dead} =
      MCP.create_server(
        %{name: "Dead", handle: "dead", url: "http://127.0.0.1:1", auth_type: :none},
        actor: user
      )

    assert {:ok, %{error: msg}} = Executor.call(dead, "x", %{}, context(user))
    assert is_binary(msg)
  end

  test "oauth server without tokens returns a :needs_auth soft error", %{
    user: user,
    bypass: bypass
  } do
    {:ok, oauth} =
      MCP.create_server(
        %{
          name: "O",
          handle: "oauthsvc",
          url: "http://127.0.0.1:#{bypass.port}",
          auth_type: :oauth
        },
        actor: user
      )

    assert {:ok, %{error: msg}} = Executor.call(oauth, "x", %{}, context(user))
    assert is_binary(msg)
    assert msg =~ "auth" or msg =~ "connect"
  end

  test "static_header server with a credential injects headers and succeeds", %{
    user: user,
    bypass: bypass
  } do
    {:ok, server} =
      MCP.create_server(
        %{
          name: "Keyed",
          handle: "keyed",
          url: "http://127.0.0.1:#{bypass.port}",
          auth_type: :static_header
        },
        actor: user
      )

    {:ok, _cred} =
      MCP.upsert_static_headers(
        %{mcp_server_id: server.id, static_headers: %{"Authorization" => "Bearer secret"}},
        actor: user
      )

    assert {:ok, result} = Executor.call(server, "echo", %{}, context(user))
    refute Map.has_key?(result, :error)
  end

  test "static_header server WITHOUT a credential returns a soft error", %{
    user: user,
    bypass: bypass
  } do
    {:ok, server} =
      MCP.create_server(
        %{
          name: "NoCred",
          handle: "nocred",
          url: "http://127.0.0.1:#{bypass.port}",
          auth_type: :static_header
        },
        actor: user
      )

    assert {:ok, %{error: msg}} = Executor.call(server, "echo", %{}, context(user))
    assert is_binary(msg)
  end

  test "static_header server with an %Ash.NotLoaded{} user yields a soft error, never crashes", %{
    user: user,
    bypass: bypass
  } do
    {:ok, server} =
      MCP.create_server(
        %{
          name: "Keyed2",
          handle: "keyed2",
          url: "http://127.0.0.1:#{bypass.port}",
          auth_type: :static_header
        },
        actor: user
      )

    # A stored credential exists, but the context's :user is a NotLoaded
    # relationship struct. resolve_headers/2 must NOT match it as a real User
    # (which would hand a bogus actor to Ash); it must fall through to the
    # soft `:no_credential` error. Defense-in-depth for the runner-side fix.
    {:ok, _cred} =
      MCP.upsert_static_headers(
        %{mcp_server_id: server.id, static_headers: %{"Authorization" => "Bearer secret"}},
        actor: user
      )

    not_loaded_context = %{
      user: %Ash.NotLoaded{field: :user, type: :relationship},
      user_id: user.id,
      conversation_id: nil
    }

    assert {:ok, %{error: msg}} = Executor.call(server, "echo", %{}, not_loaded_context)
    assert is_binary(msg)
  end

  test "a disabled server returns a soft error without dialing", %{user: user, bypass: bypass} do
    {:ok, server} =
      MCP.create_server(
        %{
          name: "Off",
          handle: "off",
          url: "http://127.0.0.1:#{bypass.port}",
          auth_type: :none,
          enabled?: false
        },
        actor: user
      )

    assert {:ok, %{error: msg}} = Executor.call(server, "echo", %{}, context(user))
    assert is_binary(msg)
  end

  # `classify/1` is a pure function over plain maps; these reasons cannot be
  # produced by the canned-success Bypass mock, so we unit-test it directly.
  describe "classify/1" do
    test "maps a -32601 method-not-found error (atom- and string-keyed)" do
      assert Executor.classify(%{code: -32_601}) == :method_not_found
      assert Executor.classify(%{"code" => -32_601}) == :method_not_found
    end

    test "maps HTTP 401 and JSON-RPC -32001 to :needs_auth" do
      assert Executor.classify(%{code: 401}) == :needs_auth
      assert Executor.classify(%{code: -32_001}) == :needs_auth
      assert Executor.classify(%{"code" => 401}) == :needs_auth
      assert Executor.classify(%{"code" => -32_001}) == :needs_auth
    end

    test "passes any other reason through unchanged" do
      assert Executor.classify(:econnrefused) == :econnrefused
      assert Executor.classify(%{code: 500}) == %{code: 500}
      assert Executor.classify({:shutdown, :boom}) == {:shutdown, :boom}
    end
  end
end
