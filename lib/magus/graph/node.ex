defmodule Magus.Graph.Node do
  @moduledoc """
  Idempotent node upsert via Cypher MERGE.

  Properties whose key is in `@vector_props` AND whose value is a non-empty
  list of numbers are emitted as `vecf32([...])` so they are stored as
  FalkorDB native vectors. This is required for the node to participate in
  vector indices created via `Magus.Graph.Vector.create_index/4`. All other
  list-valued properties (including numeric lists with non-vector keys) are
  kept as plain Cypher arrays.

  The allowlist prevents arbitrary numeric lists (e.g. `quantities: [1, 2, 3]`)
  from being silently corrupted into a vector type.
  """

  @vector_props ~w(embedding summary_embedding)a
  @vector_prop_strings ~w(embedding summary_embedding)

  def upsert(graph_name, label, %{id: id} = properties) do
    {vector_props, plain_props} = split_vector_props(properties)

    vector_set_clauses =
      vector_props
      |> Enum.map(fn {key, vec} -> "SET n.#{key} = vecf32(#{encode_float_list(vec)})" end)
      |> Enum.join("\n")

    cypher = """
    MERGE (n:#{label} {id: $id})
    SET n += $props
    #{vector_set_clauses}
    RETURN n
    """

    Magus.Graph.query(graph_name, cypher, %{id: id, props: plain_props})
  end

  defp split_vector_props(properties) do
    Enum.reduce(properties, {%{}, %{}}, fn {key, value}, {vectors, plain} ->
      if vector_prop?(key) and vector_value?(value) do
        {Map.put(vectors, key, value), plain}
      else
        {vectors, Map.put(plain, key, value)}
      end
    end)
  end

  defp vector_prop?(key) when is_atom(key), do: key in @vector_props
  defp vector_prop?(key) when is_binary(key), do: key in @vector_prop_strings
  defp vector_prop?(_), do: false

  defp vector_value?([_ | _] = list), do: Enum.all?(list, &is_number/1)
  defp vector_value?(_), do: false

  defp encode_float_list(list) do
    "[" <>
      Enum.map_join(list, ", ", fn
        n when is_integer(n) -> Float.to_string(n * 1.0)
        f when is_float(f) -> Float.to_string(f)
      end) <>
      "]"
  end
end
