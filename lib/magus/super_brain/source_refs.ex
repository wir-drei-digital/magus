defmodule Magus.SuperBrain.SourceRefs do
  @moduledoc """
  Encode/decode for the `source_refs` property denormalized onto super-graph
  `SourcePointer` nodes.

  A `SourcePointer` links a `CanonicalEntity` to one Layer 1 entity in one
  source graph. `source_refs` records the `(resource_type, resource_id)` pairs
  (brain pages, drafts, files, ...) that entity actually appears in, pulled
  from the Layer 1 `Episode-[:HAS_ENTITY]->Entity` structure at build time.
  This lets retrieval surface page-level provenance ("page X in brain Y")
  without a per-request Layer 1 lookup, matching the super graph's role as a
  read-optimized index.

  Stored as a sorted, de-duplicated JSON array of
  `%{"resource_type", "resource_id"}` maps so a full rebuild and the
  incremental builder produce byte-identical values for the same data.

  Titles are NOT stored here: a page/draft rename does not re-extract content
  (the fingerprint is over body text), so a graph-stored title would go stale.
  Callers resolve titles from Postgres at query time.
  """

  @doc """
  Build a normalized ref list from Layer 1 `"resource_type|resource_id"`
  strings (the `collect(DISTINCT ep.resource_type + '|' + ep.resource_id)`
  shape). Nulls/blanks are dropped.
  """
  @spec from_pair_strings(list() | term()) :: [map()]
  def from_pair_strings(strings) when is_list(strings) do
    strings
    |> Enum.map(&parse_pair/1)
    |> Enum.reject(&is_nil/1)
    |> normalize()
  end

  def from_pair_strings(_), do: []

  @doc "Encode a ref list to the JSON string stored on the SourcePointer."
  @spec encode([map()]) :: String.t()
  def encode(refs) when is_list(refs), do: Jason.encode!(refs)

  @doc """
  Decode the stored JSON string into `[%{resource_type: ..., resource_id: ...}]`
  (atom keys). Returns `[]` for nil/blank/malformed input.
  """
  @spec decode(term()) :: [%{resource_type: String.t(), resource_id: String.t()}]
  def decode(json) when is_binary(json) and json != "" do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) ->
        list
        |> Enum.map(fn
          %{"resource_type" => rt, "resource_id" => rid} when is_binary(rt) and is_binary(rid) ->
            %{resource_type: rt, resource_id: rid}

          _ ->
            nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  def decode(_), do: []

  defp parse_pair(s) when is_binary(s) do
    case String.split(s, "|", parts: 2) do
      [rt, rid] when rt != "" and rid != "" -> %{"resource_type" => rt, "resource_id" => rid}
      _ -> nil
    end
  end

  defp parse_pair(_), do: nil

  # Dedup + deterministic sort so full and incremental builds agree byte-for-byte.
  defp normalize(maps) do
    maps
    |> Enum.uniq()
    |> Enum.sort_by(fn %{"resource_type" => rt, "resource_id" => rid} -> {rt, rid} end)
  end
end
