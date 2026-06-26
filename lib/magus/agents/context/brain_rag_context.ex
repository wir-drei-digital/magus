defmodule Magus.Agents.Context.BrainRagContext do
  @moduledoc """
  Builds brain RAG context for AI agents.

  On every message, searches the user's brain(s) for semantically relevant
  page/source chunks and injects them into the system prompt. Works
  independently of whether the brain pane is open.

  Post-Phase-A: operates on the markdown-as-storage model. Hits come from
  `Magus.Brain.search_chunks/3` (semantic) with a fallback to
  `Magus.Brain.search_pages_text/3` (Postgres FTS) when embedding
  generation fails.
  """

  require Logger
  require Ash.Query

  alias Magus.Brain
  alias Magus.Brain.BrainResource
  alias Magus.Brain.Page
  alias Magus.Brain.Source
  alias Magus.Files.EmbeddingModel
  alias Magus.Workspaces.ResourceAccess

  @max_results 5
  @min_query_length 10
  @snippet_max_chars 1000

  @spec build(map()) :: String.t() | nil
  def build(%{query: query, user: %{} = user} = opts)
      when is_binary(query) and byte_size(query) >= @min_query_length do
    brain_ids = resolve_brain_ids(opts)

    if brain_ids == [] do
      nil
    else
      search_and_format(query, resolve_query_embedding(opts, query), brain_ids, user)
    end
  rescue
    e ->
      Logger.warning("Brain RAG context failed: #{Exception.message(e)}")
      nil
  end

  def build(_), do: nil

  defp resolve_brain_ids(%{brain_id: brain_id}) when is_binary(brain_id) and brain_id != "" do
    [brain_id]
  end

  defp resolve_brain_ids(%{custom_agent_id: agent_id} = opts) when is_binary(agent_id) do
    granted_ids =
      ResourceAccess
      |> Ash.Query.filter(
        resource_type == :brain and grantee_type == :custom_agent and
          grantee_id == ^agent_id
      )
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.resource_id)

    workspace_scoped = scope_brains_by_workspace(granted_ids, Map.get(opts, :workspace_id))

    case workspace_scoped do
      [] -> resolve_user_brains(opts)
      ids -> ids
    end
  end

  defp resolve_brain_ids(opts), do: resolve_user_brains(opts)

  defp resolve_user_brains(%{user: user} = opts) do
    result =
      case Map.get(opts, :workspace_id) do
        nil -> Brain.list_brains(actor: user)
        workspace_id -> Brain.list_brains_for_workspace(workspace_id, actor: user)
      end

    case result do
      {:ok, brains} -> Enum.map(brains, & &1.id)
      _ -> []
    end
  end

  # Filters a list of brain IDs to only those matching the workspace scope.
  # nil workspace_id ⇒ only personal brains (workspace_id IS NULL).
  # set workspace_id ⇒ only brains in that workspace.
  # Uses `authorize?: false` because the agent's grant already established
  # access for the original ID set; this query only narrows by workspace.
  defp scope_brains_by_workspace([], _workspace_id), do: []

  defp scope_brains_by_workspace(brain_ids, nil) do
    BrainResource
    |> Ash.Query.filter(id in ^brain_ids and is_nil(workspace_id) and is_archived == false)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.id)
  end

  defp scope_brains_by_workspace(brain_ids, workspace_id) do
    BrainResource
    |> Ash.Query.filter(
      id in ^brain_ids and workspace_id == ^workspace_id and is_archived == false
    )
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.id)
  end

  # Reuse a precomputed query embedding when the caller supplies one (the agent
  # context builder embeds the query once and shares it across retrievers). A
  # nil value means the upstream embed was attempted and failed/timed out, so we
  # skip semantic search and fall back to FTS. When the key is absent entirely,
  # embed here (legacy callers and tests).
  defp resolve_query_embedding(opts, query) do
    case Map.fetch(opts, :query_embedding) do
      {:ok, embedding} when is_list(embedding) -> {:ok, embedding}
      {:ok, _} -> {:error, :no_embedding}
      :error -> EmbeddingModel.embed(query)
    end
  end

  defp search_and_format(query, embedding_result, brain_ids, user) do
    hits = search_across_brains(query, embedding_result, brain_ids, user)

    case hits do
      [] -> nil
      _ -> format(hits, user)
    end
  end

  # Runs semantic search across every accessible brain id and flattens the
  # results, capped at @max_results. Falls back to FTS when no embedding is
  # available.
  defp search_across_brains(_query, {:ok, embedding}, brain_ids, user) do
    brain_ids
    |> Enum.flat_map(fn brain_id ->
      safe_search_chunks(brain_id, embedding, user)
    end)
    |> Enum.sort_by(&hit_sort_key/1, :desc)
    |> Enum.take(@max_results)
  end

  defp search_across_brains(query, {:error, _}, brain_ids, user) do
    text_search_fallback(query, brain_ids, user)
  end

  defp safe_search_chunks(brain_id, embedding, user) do
    Brain.search_chunks(brain_id, embedding, limit: @max_results, actor: user)
  rescue
    e ->
      Logger.warning("Brain.search_chunks failed: #{Exception.message(e)}")
      []
  end

  # Text-search fallback returns `:page` hits (no `:source_chunk`). We map
  # them into the same shape the formatter consumes downstream.
  defp text_search_fallback(query, brain_ids, user) do
    brain_ids
    |> Enum.flat_map(fn brain_id ->
      try do
        Brain.search_pages_text(brain_id, query, limit: @max_results, actor: user)
      rescue
        e ->
          Logger.warning("Brain.search_pages_text failed: #{Exception.message(e)}")
          []
      end
    end)
    |> Enum.map(&page_text_hit_to_chunk/1)
    |> Enum.take(@max_results)
  end

  defp page_text_hit_to_chunk(%{kind: :page} = hit) do
    %{
      kind: :page_chunk,
      score: Map.get(hit, :rank, 0.0),
      brain_id: hit.brain_id,
      page_id: hit.page_id,
      snippet: Map.get(hit, :snippet, "")
    }
  end

  defp hit_sort_key(%{score: score}) when is_number(score), do: score
  defp hit_sort_key(_), do: 0.0

  defp format(hits, user) do
    {page_ids, source_ids} =
      Enum.reduce(hits, {MapSet.new(), MapSet.new()}, fn
        %{kind: :page_chunk, page_id: id}, {pids, sids} when is_binary(id) ->
          {MapSet.put(pids, id), sids}

        %{kind: :source_chunk, source_id: id}, {pids, sids} when is_binary(id) ->
          {pids, MapSet.put(sids, id)}

        _, acc ->
          acc
      end)

    page_cache = load_pages(MapSet.to_list(page_ids), user)
    source_cache = load_sources(MapSet.to_list(source_ids), user)

    entries =
      hits
      |> Enum.map(&format_hit(&1, page_cache, source_cache))
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    if entries == "" do
      nil
    else
      """
      <brain_knowledge>
      The following content from your knowledge brain may be relevant:

      #{entries}
      </brain_knowledge>\
      """
    end
  end

  defp load_pages([], _user), do: %{}

  defp load_pages(ids, user) do
    Map.new(ids, fn id ->
      case Ash.get(Page, id, actor: user) do
        {:ok, page} -> {id, page}
        _ -> {id, nil}
      end
    end)
  end

  defp load_sources([], _user), do: %{}

  defp load_sources(ids, user) do
    Map.new(ids, fn id ->
      case Ash.get(Source, id, actor: user) do
        {:ok, source} -> {id, source}
        _ -> {id, nil}
      end
    end)
  end

  defp format_hit(%{kind: :page_chunk, page_id: page_id} = hit, page_cache, _source_cache) do
    page = Map.get(page_cache, page_id)
    title = (page && page.title) || "Untitled page"
    snippet = format_snippet(Map.get(hit, :snippet))

    if snippet == "" do
      nil
    else
      "### From page \"#{title}\"\n- #{snippet}"
    end
  end

  defp format_hit(%{kind: :source_chunk, source_id: source_id} = hit, _page_cache, source_cache) do
    source = Map.get(source_cache, source_id)
    label = source_label(source)
    snippet = format_snippet(Map.get(hit, :snippet))

    if snippet == "" do
      nil
    else
      "### From source \"#{label}\"\n- #{snippet}"
    end
  end

  defp format_hit(_, _, _), do: nil

  defp source_label(nil), do: "Unknown source"

  defp source_label(source) do
    cond do
      is_binary(source.title) and source.title != "" -> source.title
      is_binary(source.url) and source.url != "" -> source.url
      true -> "Unknown source"
    end
  end

  defp format_snippet(nil), do: ""

  defp format_snippet(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, @snippet_max_chars)
  end

  defp format_snippet(_), do: ""
end
