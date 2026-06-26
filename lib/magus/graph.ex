defmodule Magus.Graph do
  @moduledoc """
  Public API for the generic graph engine.

  All operations are scoped to a named FalkorDB graph. Authorization
  is by graph name: connecting to a graph is itself the access decision.
  """

  alias Magus.Graph.{Connection, Query, Node, Edge}

  @doc "Run a parameterized Cypher query against the named graph."
  def query(graph_name, cypher, params \\ %{}) when is_binary(graph_name) do
    case Magus.Graph.CircuitBreaker.state(Magus.Graph.CircuitBreaker) do
      :open ->
        {:error, :graph_unavailable}

      :closed ->
        bound = Query.bind_params(cypher, params)

        case Connection.command(["GRAPH.QUERY", prefixed(graph_name), bound]) do
          {:ok, result} ->
            Magus.Graph.CircuitBreaker.record_success(Magus.Graph.CircuitBreaker)
            Query.decode_result(result)

          {:error, _} = err ->
            Magus.Graph.CircuitBreaker.record_failure(Magus.Graph.CircuitBreaker)
            err
        end
    end
  end

  @doc "Idempotently upsert a node identified by `:id` in `properties`."
  def upsert_node(graph_name, label, properties) do
    Node.upsert(graph_name, label, properties)
  end

  @doc "Idempotently upsert an edge between two nodes."
  def upsert_edge(graph_name, endpoints, relation_label, properties) do
    Edge.upsert(graph_name, endpoints, relation_label, properties)
  end

  @doc "Delete a graph entirely. Useful for tests and cleanup."
  def drop(graph_name), do: Connection.command(["GRAPH.DELETE", prefixed(graph_name)])

  defp prefixed(graph_name) do
    prefix =
      Application.fetch_env!(:magus, Magus.Graph)
      |> Keyword.get(:graph_name_prefix, "")

    prefix <> graph_name
  end
end
