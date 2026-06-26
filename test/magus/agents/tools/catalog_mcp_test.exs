defmodule Magus.Agents.Tools.CatalogMcpTest do
  # NOTE: The brief specified `Magus.DataCase` + `Magus.AccountsFixtures.user_fixture()`,
  # but neither exists in this codebase. This suite uses `Magus.ResourceCase` +
  # `generate(user())` (the real helpers), matching the prior MCP task's resolution
  # documented in test/magus/chat/message_queue_test.exs. Behavior asserted is identical.
  use Magus.ResourceCase, async: false

  alias Magus.Agents.Tools.Catalog

  setup do
    user = generate(user())

    {:ok, server} =
      Magus.MCP.create_server(
        %{name: "Svc", handle: "svc", url: "https://example.test", auth_type: :none},
        actor: user
      )

    {:ok, server} =
      Magus.MCP.update_server_cached_tools(
        server,
        %{
          cached_tools: [
            %{
              "name" => "do_thing",
              "description" => "Does a thing",
              "input_schema" => %{"type" => "object", "properties" => %{}},
              "annotations" => %{}
            }
          ]
        },
        actor: user
      )

    {:ok, user: user, server: server}
  end

  test "entries/1 with a user includes {:mcp, server_id} entries", %{user: user, server: server} do
    entries = Catalog.entries(%{user: user})
    mcp = Enum.filter(entries, fn e -> match?({:mcp, _}, e.source) end)
    assert Enum.any?(mcp, fn e -> e.name == "svc__do_thing" and e.source == {:mcp, server.id} end)
  end

  test "entries/1 without a user is static-only (no MCP)", _ do
    entries = Catalog.entries(%{})
    refute Enum.any?(entries, fn e -> match?({:mcp, _}, e.source) end)
  end

  test "resolve/2 reverse-looks-up coined name to (server_id, remote_name)", %{
    user: user,
    server: server
  } do
    {modules, mcp_tools, unknown} = Catalog.resolve(["svc__do_thing"], %{user: user})
    assert modules == []
    assert unknown == []

    assert [
             %{
               coined_name: "svc__do_thing",
               server_id: sid,
               remote_name: "do_thing",
               tool: %ReqLLM.Tool{}
             }
           ] = mcp_tools

    assert sid == server.id
  end

  test "resolve/2 drops MCP names the actor cannot access", _ do
    other = generate(user())
    {modules, mcp_tools, unknown} = Catalog.resolve(["svc__do_thing"], %{user: other})
    assert modules == []
    assert mcp_tools == []
    assert unknown == ["svc__do_thing"]
  end

  test "resolve/2 still resolves internal modules", %{user: user} do
    {modules, mcp_tools, _unknown} = Catalog.resolve(["web_search"], %{user: user})
    assert mcp_tools == []
    assert Enum.any?(modules, &(&1 == Magus.Agents.Tools.Web.WebSearch))
  end
end
