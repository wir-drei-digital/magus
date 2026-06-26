defmodule Magus.MCP.ToolAdapterCoiningTest do
  use ExUnit.Case, async: true

  alias Magus.MCP.ToolAdapter

  describe "coin_tool_name/2" do
    test "joins handle and slugified remote name with __" do
      assert ToolAdapter.coin_tool_name("github", "create_issue") == "github__create_issue"
    end

    test "preserves remote names that already contain __" do
      name = ToolAdapter.coin_tool_name("gh", "repos__create__issue")
      assert name =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/
      assert String.starts_with?(name, "gh__")
    end

    test "slugifies illegal characters to underscore" do
      name = ToolAdapter.coin_tool_name("svc", "search-files.v2")
      assert name =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/
    end

    test "truncates to <= 64 chars with a stable hash suffix" do
      long = String.duplicate("a", 200)
      name = ToolAdapter.coin_tool_name("handle", long)
      assert String.length(name) <= 64
      # deterministic
      assert name == ToolAdapter.coin_tool_name("handle", long)
    end

    test "is deterministic for the same inputs" do
      assert ToolAdapter.coin_tool_name("a", "b__c") == ToolAdapter.coin_tool_name("a", "b__c")
    end
  end

  describe "to_reqllm_tool/3" do
    setup do
      server = %Magus.MCP.Server{id: Ecto.UUID.generate(), handle: "svc", name: "Svc"}
      {:ok, server: server}
    end

    test "builds a ReqLLM.Tool with parameter_schema from input_schema", %{server: server} do
      cached = %{
        "name" => "create_issue",
        "description" => "Create an issue",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{"title" => %{"type" => "string"}},
          "required" => ["title"]
        },
        "annotations" => %{}
      }

      assert {:ok, entry} = ToolAdapter.to_reqllm_tool(cached, server, %{})
      assert entry.coined_name == "svc__create_issue"
      assert entry.remote_name == "create_issue"
      assert entry.server_id == server.id
      assert %ReqLLM.Tool{} = entry.tool
      assert entry.tool.name == "svc__create_issue"
    end

    test "enforces additionalProperties:false on object schemas", %{server: server} do
      cached = %{
        "name" => "t",
        "description" => "",
        "input_schema" => %{"type" => "object", "properties" => %{}},
        "annotations" => %{}
      }

      assert {:ok, entry} = ToolAdapter.to_reqllm_tool(cached, server, %{})
      assert entry.tool.parameter_schema["additionalProperties"] == false
    end

    test "returns {:error, _} for a tool whose name cannot be coined", %{server: server} do
      cached = %{"name" => "", "description" => "", "input_schema" => %{}, "annotations" => %{}}
      assert {:error, _} = ToolAdapter.to_reqllm_tool(cached, server, %{})
    end
  end
end
