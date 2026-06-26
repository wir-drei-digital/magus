defmodule Magus.MCP.ClientTest do
  use ExUnit.Case, async: true

  alias Magus.MCP.Client

  test "normalize_tools extracts the tools list from a response struct" do
    response = %Anubis.MCP.Response{result: %{"tools" => [%{"name" => "a"}, %{"name" => "b"}]}}
    assert {:ok, [%{"name" => "a"}, %{"name" => "b"}]} = Client.normalize_tools({:ok, response})
  end

  test "normalize_tools tolerates a plain-map response" do
    assert {:ok, [%{"name" => "x"}]} =
             Client.normalize_tools({:ok, %{result: %{"tools" => [%{"name" => "x"}]}}})
  end

  test "normalize_tools surfaces errors" do
    assert {:error, %Anubis.MCP.Error{}} =
             Client.normalize_tools({:error, %Anubis.MCP.Error{}})
  end

  test "normalize_result returns the result payload" do
    response = %Anubis.MCP.Response{result: %{"content" => [%{"type" => "text", "text" => "hi"}]}}

    assert {:ok, %{"content" => [%{"type" => "text", "text" => "hi"}]}} =
             Client.normalize_result({:ok, response})
  end
end
