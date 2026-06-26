defmodule Magus.Agents.Context.SuperBrainRagContext do
  @moduledoc """
  Builds Super Brain context for AI agents.

  On every message, queries the actor's Layer 2 super graph (or the
  Layer 1 fan-out on cold-start / read-set drift) for entities
  semantically related to the user's prompt and injects a compact block
  into the system prompt. Mirrors `BrainRagContext` but operates on the
  cross-source canonical layer surfaced by `Magus.SuperBrain.Retrieval`.

  Returns `nil` when the query is too short, when the embedder fails,
  when retrieval has no results, or when the backend is unavailable.
  The `append_context/2` helper in `Builder` ignores `nil`.
  """

  require Logger
  require Ash.Query

  alias Magus.Files.EmbeddingModel
  alias Magus.SuperBrain.Retrieval

  @max_results 8
  @min_query_length 10
  # Cap how many source references we list per entity so the block stays
  # compact on the per-message hot path; extras are summarized as "+N more".
  @max_refs_per_entity 5

  @spec build(map()) :: String.t() | nil
  def build(%{query: query, user: %{} = user} = opts)
      when is_binary(query) and byte_size(query) >= @min_query_length do
    if Magus.SuperBrain.enabled?() do
      do_build(query, user, opts)
    else
      nil
    end
  end

  def build(_), do: nil

  defp do_build(query, user, opts) do
    workspace_context = Map.get(opts, :workspace_id)

    case EmbeddingModel.embed(query) do
      {:ok, embedding} ->
        case Retrieval.search(user,
               query: query,
               query_embedding: embedding,
               workspace_context: workspace_context,
               limit: @max_results
             ) do
          {:ok, %{entities: entities}} when entities != [] ->
            format(entities)

          {:ok, results} when is_list(results) and results != [] ->
            format_legacy(results)

          _ ->
            nil
        end

      _ ->
        nil
    end
  rescue
    e ->
      Logger.warning("SuperBrain RAG context failed: #{Exception.message(e)}")
      nil
  end

  @doc false
  # Exposed for tests: render the `<super_brain>` block from retrieval
  # entities (each with `:sources` carrying `:source_refs`).
  def format(entities) do
    # Resolve page/draft titles once for the whole block (batched), then render.
    titles = resolve_titles(entities)
    entries = Enum.map_join(entities, "\n", &format_super_entity(&1, titles))

    """
    <super_brain>
    Concepts from your knowledge graph relevant to this query. To read a source,
    call the tool noted with the id, then search within it by the entity name:
      brain page -> read_brain.read_page (page_id)
      draft -> read_draft (draft_id)

    #{entries}
    </super_brain>\
    """
  end

  defp format_super_entity(e, titles) do
    name = Map.get(e, :name) || "?"
    type = Map.get(e, :primary_type) || Map.get(e, :type) || "?"
    subtype = Map.get(e, :normalized_subtype) || Map.get(e, :subtype)
    subtype_str = if is_binary(subtype) and subtype != "", do: "/#{subtype}", else: ""

    base = "- #{name} [#{type}#{subtype_str}]"

    case entity_refs(e) do
      [] ->
        # Pre-rebuild super graphs (or non-loadable source types) have no
        # page-level refs. Fall back to the graph-name "seen in" hint.
        sources_str = e |> Map.get(:sources, []) |> Enum.map_join(", ", &short_source/1)
        if sources_str == "", do: base, else: base <> " (seen in: #{sources_str})"

      refs ->
        rendered = render_refs(refs, titles)
        base <> "\n" <> Enum.map_join(rendered, "\n", &"    #{&1}")
    end
  end

  # De-duplicated `[%{resource_type, resource_id}]` across all of an entity's
  # sources.
  defp entity_refs(e) do
    e
    |> Map.get(:sources, [])
    |> Enum.flat_map(&Map.get(&1, :source_refs, []))
    |> Enum.uniq()
  end

  defp render_refs(refs, titles) do
    capped = Enum.take(refs, @max_refs_per_entity)
    rendered = Enum.map(capped, &render_ref(&1, titles))

    case length(refs) - length(capped) do
      extra when extra > 0 -> rendered ++ ["+#{extra} more"]
      _ -> rendered
    end
  end

  defp render_ref(%{resource_type: "brain_page", resource_id: id}, titles) do
    case Map.get(titles, id) do
      %{title: t, brain_title: bt} when is_binary(t) ->
        brain = if is_binary(bt), do: "brain \"#{bt}\" > ", else: ""
        "#{brain}page \"#{t}\" (page_id: #{id})"

      _ ->
        "brain page (page_id: #{id})"
    end
  end

  defp render_ref(%{resource_type: "draft", resource_id: id}, titles) do
    case Map.get(titles, id) do
      t when is_binary(t) -> "draft \"#{t}\" (draft_id: #{id})"
      _ -> "draft (draft_id: #{id})"
    end
  end

  # Other source types (brain_source, file, memory, message, brain_pin) have
  # no specialized read tool wired here; surface the ref for transparency.
  defp render_ref(%{resource_type: rt, resource_id: id}, _titles), do: "#{rt} (id: #{id})"

  # Batch-resolve titles from Postgres (always fresh; never stored in the graph
  # because a rename does not re-extract content). Keyed by resource_id.
  defp resolve_titles(entities) do
    refs = Enum.flat_map(entities, &entity_refs/1)
    by_type = Enum.group_by(refs, & &1.resource_type, & &1.resource_id)

    page_titles =
      by_type |> Map.get("brain_page", []) |> Enum.uniq() |> resolve_page_titles()

    draft_titles =
      by_type |> Map.get("draft", []) |> Enum.uniq() |> resolve_draft_titles()

    Map.merge(page_titles, draft_titles)
  end

  defp resolve_page_titles([]), do: %{}

  defp resolve_page_titles(ids) do
    case Magus.Brain.Page
         |> Ash.Query.filter(id in ^ids)
         |> Ash.Query.load(:brain)
         |> Ash.read(authorize?: false) do
      {:ok, pages} ->
        Map.new(pages, fn p ->
          brain_title = if is_map(p.brain), do: Map.get(p.brain, :title), else: nil
          {p.id, %{title: p.title, brain_title: brain_title}}
        end)

      _ ->
        %{}
    end
  end

  defp resolve_draft_titles([]), do: %{}

  defp resolve_draft_titles(ids) do
    case Magus.Drafts.Draft
         |> Ash.Query.filter(id in ^ids)
         |> Ash.read(authorize?: false) do
      {:ok, drafts} -> Map.new(drafts, fn d -> {d.id, d.title} end)
      _ -> %{}
    end
  end

  defp short_source(%{graph_name: g}) when is_binary(g), do: g
  defp short_source(%{"graph_name" => g}) when is_binary(g), do: g
  defp short_source(_), do: "?"

  defp format_legacy(results) do
    entries =
      Enum.map_join(results, "\n", fn r ->
        entity = Map.get(r, :entity) || %{}
        name = Map.get(entity, :name) || "?"
        type = Map.get(entity, :type) || "?"
        graph = Map.get(r, :graph_name) || "?"
        "- #{name} [#{type}] (from #{graph})"
      end)

    """
    <super_brain>
    Relevant entities from your accumulated knowledge graph:

    #{entries}
    </super_brain>\
    """
  end
end
