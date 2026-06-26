defmodule Magus.MCP.ToolAdapterTest do
  use ExUnit.Case, async: true

  alias Magus.MCP.ToolAdapter

  test "normalizes a tool definition to the stored shape" do
    raw = %{
      "name" => "create_event",
      "description" => "Create a calendar event",
      "inputSchema" => %{"type" => "object", "properties" => %{"title" => %{"type" => "string"}}},
      "annotations" => %{"destructiveHint" => true, "title" => "Create Event"}
    }

    assert ToolAdapter.normalize_tool(raw) ==
             {:ok,
              %{
                "name" => "create_event",
                "description" => "Create a calendar event",
                "input_schema" => %{
                  "type" => "object",
                  "properties" => %{"title" => %{"type" => "string"}}
                },
                "annotations" => %{"destructiveHint" => true, "title" => "Create Event"}
              }}
  end

  test "supplies defaults for missing description and annotations" do
    assert ToolAdapter.normalize_tool(%{"name" => "ping"}) ==
             {:ok,
              %{
                "name" => "ping",
                "description" => "",
                "input_schema" => %{},
                "annotations" => %{}
              }}
  end

  test "returns an error for a tool missing a name" do
    raw = %{"description" => "no name here"}
    assert {:error, {:invalid_tool_definition, ^raw}} = ToolAdapter.normalize_tool(raw)
  end

  test "returns an error for an empty-string name" do
    assert {:error, {:invalid_tool_definition, _}} = ToolAdapter.normalize_tool(%{"name" => ""})
  end

  test "returns an error for a non-binary name" do
    assert {:error, {:invalid_tool_definition, _}} =
             ToolAdapter.normalize_tool(%{"name" => 123})
  end
end
