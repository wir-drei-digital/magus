defmodule Magus.Graph.Query do
  @moduledoc """
  Cypher query helpers: parameter binding and result decoding.

  FalkorDB's GRAPH.QUERY returns a 3-tuple: [columns, rows, metadata].
  """

  @doc "Substitutes $name placeholders in the Cypher string with literal values."
  def bind_params(cypher, params) when is_map(params) do
    Regex.replace(~r/\$([a-zA-Z_][a-zA-Z0-9_]*)/, cypher, fn _, name ->
      key = String.to_existing_atom(name)
      value = Map.fetch!(params, key)
      encode(value)
    end)
  end

  defp encode(s) when is_binary(s), do: "'" <> escape_string(s) <> "'"
  defp encode(n) when is_integer(n), do: Integer.to_string(n)
  defp encode(f) when is_float(f), do: Float.to_string(f)
  defp encode(true), do: "true"
  defp encode(false), do: "false"
  defp encode(nil), do: "null"

  defp encode(m) when is_map(m) do
    "{" <>
      Enum.map_join(m, ", ", fn {k, v} -> "#{k}: #{encode(v)}" end) <>
      "}"
  end

  defp encode(list) when is_list(list) do
    "[" <> Enum.map_join(list, ", ", &encode/1) <> "]"
  end

  defp escape_string(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("'", "\\'")
  end

  @doc """
  Decodes the response returned by GRAPH.QUERY.

  Read queries return `[columns, rows, metadata]`. Write-only queries (CREATE,
  MERGE, SET without RETURN) return a single-element list with only stats; we
  normalize those to empty columns/rows.
  """
  def decode_result([columns, rows, _meta]) when is_list(columns) and is_list(rows) do
    {:ok, %{columns: columns, rows: rows}}
  end

  def decode_result([meta]) when is_list(meta) do
    {:ok, %{columns: [], rows: [], stats: meta}}
  end

  def decode_result(other), do: {:error, {:unexpected_result, other}}
end
