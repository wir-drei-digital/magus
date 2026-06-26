defmodule Magus.MCP.ServerTest do
  use Magus.ResourceCase, async: true

  alias Magus.MCP

  describe "create_server/2" do
    test "creates a personal server with valid attributes" do
      user = generate(user())

      {:ok, server} =
        MCP.create_server(
          %{name: "My Server", handle: "myserver", url: "https://93.184.216.34"},
          actor: user
        )

      assert server.name == "My Server"
      assert server.handle == "myserver"
      assert server.transport == :streamable_http
      assert server.mcp_path == "/mcp"
      assert server.auth_type == :none
      assert server.enabled? == true
      assert server.user_id == user.id
      assert server.cached_tools == []
    end

    test "rejects a URL that resolves to a private IP (SSRF)" do
      user = generate(user())
      # SSRF bypass is enabled in test config, so force the validator by using a
      # clearly-private literal AND disabling the bypass for this assertion.
      Application.put_env(:magus, Magus.MCP, allow_private_urls: false)
      on_exit(fn -> Application.put_env(:magus, Magus.MCP, allow_private_urls: true) end)

      {:error, error} =
        MCP.create_server(
          %{name: "Evil", handle: "evil", url: "http://10.1.2.3"},
          actor: user
        )

      assert_field_error(error, :url, "private")
    end

    test "enforces handle uniqueness per personal scope" do
      user = generate(user())
      attrs = %{name: "A", handle: "dupe", url: "https://93.184.216.34"}
      {:ok, _} = MCP.create_server(attrs, actor: user)

      {:error, error} =
        MCP.create_server(%{attrs | name: "B"}, actor: user)

      assert %Ash.Error.Invalid{} = error
    end
  end

  describe "sharing + policies" do
    test "a workspace member can read a workspace server shared via grant" do
      owner = generate(user())
      ws = generate(workspace(actor: owner))
      member = generate(user())
      workspace_member(user_id: member.id, workspace_id: ws.id, role: :member)

      {:ok, server} =
        MCP.create_server(
          %{name: "Team", handle: "team", url: "https://93.184.216.34", workspace_id: ws.id},
          actor: owner
        )

      # Grant workspace access (mirrors how other workspace resources share).
      {:ok, _} =
        Magus.Workspaces.grant_access(
          %{
            resource_type: :mcp_server,
            resource_id: server.id,
            grantee_type: :workspace,
            grantee_id: ws.id,
            role: :viewer
          },
          actor: owner
        )

      assert {:ok, fetched} = MCP.get_server(server.id, actor: member)
      assert fetched.id == server.id
    end

    test "an unrelated user cannot read a personal server" do
      owner = generate(user())
      other = generate(user())

      {:ok, server} =
        MCP.create_server(
          %{name: "Mine", handle: "mine", url: "https://93.184.216.34"},
          actor: owner
        )

      # A `get_by: [:id]` read returns NotFound (wrapped in Invalid) rather than
      # Forbidden so it does not leak the record's existence to an actor without
      # access. This mirrors every other workspace-scoped `get_*` in the app
      # (see Chat.get_conversation, Brain.get_brain).
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               MCP.get_server(server.id, actor: other)
    end
  end
end
