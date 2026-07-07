defmodule Magus.Agents.Tools.Brain.ReadBrain.Search do
  @moduledoc """
  `ReadBrain` action handler for `search`: semantic search across page
  chunks (`Magus.Brain.PageChunk`) and source chunks
  (`Magus.Brain.SourceChunk`), embedded server-side.

  Extracted verbatim from `Magus.Agents.Tools.Brain.ReadBrain` as part
  of the Task B11 dispatch-handler split; behavior is unchanged.
  """

  require Logger

  alias Magus.Brain
  alias Magus.Files.EmbeddingModel

  import Magus.Agents.Tools.Helpers, only: [get_param: 2]
  import Magus.Agents.Tools.Brain.ReadBrain.Support, only: [resolve_brain_pairs: 3]

  def handle_search(params, ctx, context) do
    query = get_param(params, :query)

    cond do
      is_nil(query) or query == "" ->
        {:ok, %{error: "Missing required parameter: query"}}

      true ->
        limit = get_param(params, :limit) || 10
        kind = normalize_kind(get_param(params, :kind))
        brain_pairs = resolve_brain_pairs(params, context, ctx)

        cond do
          brain_pairs == [] ->
            {:ok,
             %{
               action: "search",
               count: 0,
               results: [],
               hint: "No accessible brains."
             }}

          true ->
            do_search(query, brain_pairs, limit, kind, ctx)
        end
    end
  end

  defp normalize_kind(nil), do: :all
  defp normalize_kind("all"), do: :all
  defp normalize_kind("pages"), do: :pages
  defp normalize_kind("sources"), do: :sources
  # Any other value falls back to :all rather than failing the dispatch —
  # the LLM may invent labels and the tool stays usable.
  defp normalize_kind(_), do: :all

  defp do_search(query, brain_pairs, limit, kind, ctx) do
    case EmbeddingModel.embed(query) do
      {:ok, embedding} ->
        results =
          brain_pairs
          |> Enum.flat_map(fn {brain_id, brain_title} ->
            page_hits =
              if kind in [:all, :pages] do
                fetch_page_chunk_hits(brain_id, brain_title, embedding, limit, ctx.user)
              else
                []
              end

            source_hits =
              if kind in [:all, :sources] do
                fetch_source_chunk_hits(brain_id, brain_title, embedding, limit, ctx.user)
              else
                []
              end

            page_hits ++ source_hits
          end)
          |> Enum.sort_by(& &1.score, :desc)
          |> Enum.take(limit)

        hint =
          cond do
            results == [] and length(brain_pairs) > 1 ->
              "No semantic matches across #{length(brain_pairs)} brain(s). Hint: try a more descriptive query, or set kind to scope the search."

            results == [] ->
              "No semantic matches. Hint: the index may not be embedded yet, or try a more descriptive query."

            true ->
              "Results sorted by similarity score. Each carries enough ids for read_brain.read_page / read_source follow-up."
          end

        {:ok,
         %{
           action: "search",
           query: query,
           count: length(results),
           kind: Atom.to_string(kind),
           results: results,
           hint: hint
         }}

      {:error, reason} ->
        Logger.warning("Embedding failed for read_brain search: #{inspect(reason)}")

        {:ok,
         %{
           action: "search",
           query: query,
           count: 0,
           kind: Atom.to_string(kind),
           results: [],
           hint:
             "Semantic search unavailable (embedding API not reachable). Hint: try read_brain find_page for title/body keyword matching."
         }}
    end
  end

  defp fetch_page_chunk_hits(brain_id, brain_title, embedding, limit, user) do
    case Brain.search_page_chunks(brain_id, embedding, %{limit: limit}, actor: user) do
      {:ok, chunks} ->
        Enum.map(chunks, fn chunk ->
          page = chunk.page

          %{
            kind: "page_chunk",
            score: 1.0 - (chunk.vector_distance || 0.0),
            snippet: String.slice(chunk.content || "", 0, 500),
            brain_id: brain_id,
            brain_title: brain_title,
            page_id: page && page.id,
            page_title: page && (page.title || "Untitled"),
            source_id: nil,
            source_url: nil
          }
        end)

      _ ->
        []
    end
  end

  defp fetch_source_chunk_hits(brain_id, brain_title, embedding, limit, user) do
    case Brain.search_source_chunks(brain_id, embedding, %{limit: limit}, actor: user) do
      {:ok, chunks} ->
        Enum.map(chunks, fn chunk ->
          source = chunk.source

          %{
            kind: "source_chunk",
            score: 1.0 - (chunk.vector_distance || 0.0),
            snippet: String.slice(chunk.content || "", 0, 500),
            brain_id: brain_id,
            brain_title: brain_title,
            page_id: nil,
            page_title: nil,
            source_id: source && source.id,
            source_url: source && source.url
          }
        end)

      _ ->
        []
    end
  end
end
