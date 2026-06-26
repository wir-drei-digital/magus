defmodule Magus.MCP.RpcExposureTest do
  use Magus.ResourceCase, async: false

  alias Magus.MCP

  @moduletag :mcp_integration

  describe "Server.discover (generic action)" do
    test "runs discovery and returns the server with cached tools" do
      user = generate(user())
      bypass = Magus.MCP.MockServer.start()

      {:ok, server} =
        MCP.create_server(
          %{
            name: "S",
            handle: "svc",
            url: "http://127.0.0.1:#{bypass.port}",
            mcp_path: "/mcp",
            auth_type: :none
          },
          actor: user
        )

      assert {:ok, discovered} = MCP.discover_server(server.id, actor: user)
      assert discovered.reachability == :ok
      assert is_list(discovered.cached_tools)
      assert [%{"name" => "echo"} | _] = discovered.cached_tools
    end

    test "a user cannot discover a server they cannot read (actor-scoped)" do
      owner = generate(user())
      stranger = generate(user())
      bypass = Magus.MCP.MockServer.start()

      {:ok, server} =
        MCP.create_server(
          %{
            name: "Private",
            handle: "private",
            url: "http://127.0.0.1:#{bypass.port}",
            mcp_path: "/mcp",
            auth_type: :none
          },
          actor: owner
        )

      assert {:error, _} = MCP.discover_server(server.id, actor: stranger)
    end
  end

  describe "ServerCredential typescript exposure" do
    test "does not expose encrypted secret fields to typescript" do
      public_attrs =
        Magus.MCP.ServerCredential
        |> Ash.Resource.Info.public_attributes()
        |> Enum.map(& &1.name)

      refute :static_headers in public_attrs
      refute :oauth_tokens in public_attrs
      refute :oauth_client in public_attrs

      # Non-secret status IS readable.
      assert :status in public_attrs
      assert :mcp_server_id in public_attrs
    end
  end

  describe "rpc_action declarations (Phase 5 Task 2)" do
    # Map of resource => MapSet of {public_name, action_name} rpc_actions declared
    # in the `typescript_rpc` block. These generate the SPA client functions
    # (listMcpServers, upsertMcpStaticHeaders, …). Names are prefixed with `mcp`
    # because they are GLOBAL across the generated client.
    defp declared_rpc_actions do
      Magus.MCP
      |> AshTypescript.Rpc.Info.typescript_rpc()
      |> Map.new(fn resource_cfg ->
        actions =
          resource_cfg.rpc_actions
          |> Enum.map(&{&1.name, &1.action})
          |> MapSet.new()

        {resource_cfg.resource, actions}
      end)
    end

    test "Server exposes the expected CRUD + discovery rpc_actions" do
      server_actions = Map.fetch!(declared_rpc_actions(), Magus.MCP.Server)

      assert MapSet.subset?(
               MapSet.new([
                 {:list_mcp_servers, :read},
                 {:get_mcp_server, :read},
                 {:create_mcp_server, :create},
                 {:update_mcp_server, :update},
                 {:toggle_mcp_server, :toggle},
                 {:destroy_mcp_server, :destroy},
                 {:discover_mcp_server, :discover}
               ]),
               server_actions
             )
    end

    test "ServerCredential exposes credential rpc_actions but never a secret-writing oauth action" do
      cred_actions = Map.fetch!(declared_rpc_actions(), Magus.MCP.ServerCredential)

      assert MapSet.subset?(
               MapSet.new([
                 {:get_mcp_credential, :for_server_and_user},
                 {:upsert_mcp_static_headers, :upsert_static_headers},
                 {:set_mcp_credential_status, :set_status}
               ]),
               cred_actions
             )

      # OAuth token storage is server-side only — must NOT be rpc-exposed.
      action_names = Enum.map(cred_actions, &elem(&1, 1))
      refute :store_oauth_tokens in action_names
      refute :refresh_oauth_tokens in action_names
    end
  end
end
