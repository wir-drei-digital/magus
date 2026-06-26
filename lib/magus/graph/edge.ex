defmodule Magus.Graph.Edge do
  @moduledoc "Idempotent edge upsert via Cypher MERGE."

  def upsert(graph_name, endpoints, relation_label, properties) do
    %{from_label: from_label, from_id: from_id, to_label: to_label, to_id: to_id} = endpoints

    cypher = """
    MATCH (a:#{from_label} {id: $from_id})
    MATCH (b:#{to_label} {id: $to_id})
    MERGE (a)-[r:#{relation_label}]->(b)
    SET r += $props
    RETURN r
    """

    Magus.Graph.query(graph_name, cypher, %{
      from_id: from_id,
      to_id: to_id,
      props: properties
    })
  end
end
