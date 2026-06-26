defmodule Magus.Graph.ConnectionTest do
  use ExUnit.Case, async: false

  alias Magus.Graph.Connection

  describe "command/2" do
    test "PING returns PONG" do
      assert {:ok, "PONG"} = Connection.command(["PING"])
    end

    test "executes GRAPH.QUERY against a named graph" do
      graph = "test_conn_#{System.unique_integer([:positive])}"
      on_exit(fn -> Connection.command(["GRAPH.DELETE", graph]) end)

      {:ok, _result} =
        Connection.command([
          "GRAPH.QUERY",
          graph,
          "CREATE (:Foo {name: 'bar'}) RETURN 1"
        ])

      {:ok, result} =
        Connection.command([
          "GRAPH.QUERY",
          graph,
          "MATCH (n:Foo) RETURN n.name"
        ])

      assert is_list(result)
    end
  end
end
