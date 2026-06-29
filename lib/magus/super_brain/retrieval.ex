defmodule Magus.SuperBrain.Retrieval do
  @moduledoc """
  Query orchestration over the actor's Layer 2 super graph.

  Iteration 3 default path: query the actor's super graph (one row per
  `(accessor_type, user_id, workspace_id)` tuple) via the
  `:CanonicalEntity` vector index, then expand to a 1-hop neighborhood
  for GraphRAG-style support and follow `:APPEARS_IN` for provenance.

  Cold start (no super graph row yet) and read-set drift fall back to
  the iter2 per-Layer-1 fan-out implemented as
  `legacy_fan_out_search/2`. The fan-out path is the safety net that
  keeps retrieval working before the first nightly build completes and
  while a freshly-granted workspace is being rebuilt.

  Hybrid VectorRAG + GraphRAG:

    * Vector recall via `Magus.Graph.Vector.knn_search/5`.
    * 1-hop graph verification via `:RELATES_TO` edges; the mean cosine
      of neighbor embeddings against the query yields a
      `neighborhood_support` factor in `[1.0, 2.0]`.
    * Composite ranking on
      `vector_similarity × trust_tier_multiplier × importance_score_factor × neighborhood_support`.
    * Provenance walk over `:APPEARS_IN` edges to attach
      `(graph_name, mention_count, source_weight, latest_evidence_at)`
      per source.
  """

  alias Magus.SuperBrain.AccessibleGraphs
  alias Magus.SuperBrain.GraphWeight
  alias Magus.SuperBrain.Retrieval.Ranker
  alias Magus.SuperBrain.SourceRefs
  alias Magus.SuperBrain.SuperGraph

  require Ash.Query

  @default_per_graph_limit 10
  @default_result_limit 25
  @default_trust_tiers [:instruction, :evidence]
  @search_timeout_ms 5_000

  @doc """
  Search the actor's super brain.

  ## Options

    * `:query` (required) — the natural-language query. Kept for future
      reranking phases; the embedding does the recall today.
    * `:query_embedding` (required) — the dense embedding for the query.
    * `:workspace_context` — workspace id when searching from a workspace
      surface, `nil` for personal.
    * `:trust_tiers` — list of trust tiers to include. Defaults to
      `[:instruction, :evidence]` (noise is excluded).
    * `:limit` — max candidates to return after ranking. Defaults to 25.

  Super-graph-first dispatch:

    * If the actor has no `super_brain_super_graphs` row yet (cold
      start), enqueue an initial `BuildSuperFull` and fall back to the
      iter2 per-Layer-1 fan-out.
    * If the actor's read-set has drifted from the snapshot at the last
      build, enqueue a rebuild and fall back to fan-out.
    * Otherwise, query the super graph directly.
  """
  def search(actor, opts) do
    if Magus.SuperBrain.enabled?() do
      do_search(actor, opts)
    else
      # Kill switch: no retrieval, no enqueued rebuilds. Empty super-graph
      # shape so callers degrade exactly as they do for an empty result.
      {:ok, %{entities: []}}
    end
  end

  defp do_search(actor, opts) do
    _query_text = Keyword.fetch!(opts, :query)
    _query_embedding = Keyword.fetch!(opts, :query_embedding)
    workspace_context = Keyword.get(opts, :workspace_context)

    metadata = %{
      user_id: actor && Map.get(actor, :id),
      workspace_id: workspace_context
    }

    :telemetry.span([:super_brain, :retrieval], metadata, fn ->
      super_graph_name =
        AccessibleGraphs.super_graph_for(actor, workspace_context: workspace_context)

      super_row = fetch_super_graph_metadata(super_graph_name)

      {mode, result} =
        cond do
          super_row == nil or super_row.last_built_at == nil ->
            enqueue_initial_build(actor, workspace_context)
            {:cold_start, legacy_fan_out_search(actor, opts)}

          read_set_drifted?(super_row, actor, workspace_context) ->
            enqueue_rebuild(actor, workspace_context)
            {:drift, legacy_fan_out_search(actor, opts)}

          true ->
            {:super_graph, super_graph_search(super_graph_name, opts)}
        end

      enriched = Map.merge(metadata, %{mode: mode, result_count: result_count(result)})
      {result, enriched}
    end)
  end

  # Count results across the super-graph shape (`%{entities: [...]}`) and the
  # legacy fan-out shape (a bare list). Errors/unknown shapes count as 0.
  defp result_count({:ok, %{entities: entities}}) when is_list(entities), do: length(entities)
  defp result_count({:ok, list}) when is_list(list), do: length(list)
  defp result_count(_), do: 0

  # ---------------------------------------------------------------------------
  # Super-graph-first dispatch
  # ---------------------------------------------------------------------------

  defp fetch_super_graph_metadata(super_graph_name) do
    case SuperGraph
         |> Ash.Query.filter(graph_name == ^super_graph_name)
         |> Ash.read_one(authorize?: false) do
      {:ok, %SuperGraph{} = row} -> row
      _ -> nil
    end
  end

  defp read_set_drifted?(super_row, actor, workspace_context) do
    current =
      actor
      |> AccessibleGraphs.for_actor(workspace_context: workspace_context)
      |> Enum.reject(&String.starts_with?(&1, "super:"))
      |> Enum.sort()

    snapshot =
      super_row.read_set_snapshot
      |> Enum.map(fn entry -> Map.get(entry, "graph_name") || Map.get(entry, :graph_name) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    current != snapshot
  end

  defp enqueue_initial_build(actor, workspace_context) do
    accessor_type = if workspace_context == nil, do: "user", else: "workspace"

    args = %{
      "accessor_type" => accessor_type,
      "user_id" => actor.id,
      "workspace_id" => workspace_context
    }

    _ = args |> Magus.SuperBrain.Workers.BuildSuperFull.new() |> Oban.insert()
    :ok
  end

  defp enqueue_rebuild(actor, workspace_context),
    do: enqueue_initial_build(actor, workspace_context)

  # ---------------------------------------------------------------------------
  # Super-graph search (iter3 happy path)
  # ---------------------------------------------------------------------------

  defp super_graph_search(super_graph_name, opts) do
    query_embedding = Keyword.fetch!(opts, :query_embedding)
    limit = Keyword.get(opts, :limit, @default_result_limit)
    trust_tiers = Keyword.get(opts, :trust_tiers, @default_trust_tiers)
    allowed_tiers = Enum.map(trust_tiers, &Atom.to_string/1)

    case Magus.Graph.Vector.knn_search(
           super_graph_name,
           "CanonicalEntity",
           "embedding",
           query_embedding,
           k: limit * 3
         ) do
      {:ok, hits} ->
        canonicals = filter_by_tier(hits, allowed_tiers)
        ids = Enum.map(canonicals, fn h -> Map.get(h, :id) || Map.get(h, "id") end)
        neighborhoods = fetch_super_neighborhoods(super_graph_name, ids, query_embedding)
        scored = score_canonicals(canonicals, neighborhoods)

        sorted =
          scored
          |> Enum.sort_by(& &1.score, :desc)
          |> Enum.take(limit)

        enriched = Enum.map(sorted, &enrich_with_sources(super_graph_name, &1))
        {:ok, %{entities: enriched}}

      {:error, :graph_unavailable} ->
        {:ok, %{error: :all_graphs_unavailable}}

      {:error, reason} ->
        {:ok, %{error: reason}}
    end
  end

  defp filter_by_tier(hits, allowed) do
    Enum.filter(hits, fn h ->
      tier = Map.get(h, :trust_tier) || Map.get(h, "trust_tier")
      tier in allowed
    end)
  end

  defp score_canonicals(canonicals, neighborhoods) do
    Enum.map(canonicals, fn c ->
      raw_score = parse_number(Map.get(c, :score) || Map.get(c, "score"), 1.0)
      vector_sim = max(0.0, 1.0 - raw_score)
      tier_str = Map.get(c, :trust_tier) || Map.get(c, "trust_tier") || "evidence"
      tier_mult = Magus.SuperBrain.Ontology.trust_tier_multiplier(safe_atom_tier(tier_str))

      importance =
        parse_number(Map.get(c, :importance_score) || Map.get(c, "importance_score"), 1.0)

      importance_factor = importance_factor(importance)

      cid = Map.get(c, :id) || Map.get(c, "id")
      nb_support = Map.get(neighborhoods, cid, 1.0)

      c
      |> ensure_atom_keys()
      |> Map.put(:score, vector_sim * tier_mult * importance_factor * nb_support)
      |> Map.put(:neighborhood_support, nb_support)
    end)
  end

  # Log-compress importance so a canonical with hundreds of appearances
  # cannot crowd out a vector-strong but rarely-mentioned entity. Growth
  # is bounded: each 10x in raw importance adds 1.0 to the factor.
  #
  #   importance =   0   → 1.0   (no boost)
  #   importance =   1   → 1.301
  #   importance =  10   → 2.041
  #   importance = 100   → 3.004
  #   importance = 1000  → 4.001
  defp importance_factor(importance) when is_number(importance) do
    1.0 + :math.log10(1.0 + max(0.0, importance))
  end

  defp importance_factor(_), do: 1.0

  defp ensure_atom_keys(hit) when is_map(hit) do
    Enum.reduce(hit, %{}, fn
      {k, v}, acc when is_atom(k) ->
        Map.put(acc, k, v)

      {k, v}, acc when is_binary(k) ->
        try do
          Map.put(acc, String.to_existing_atom(k), v)
        rescue
          ArgumentError -> Map.put(acc, k, v)
        end
    end)
  end

  defp safe_atom_tier("instruction"), do: :instruction
  defp safe_atom_tier("evidence"), do: :evidence
  defp safe_atom_tier("noise"), do: :noise
  defp safe_atom_tier(_), do: :evidence

  # Fetch 1-hop neighborhoods for the super-graph canonical ids and fold
  # them into a `%{id => support}` map. We return one row per (canonical,
  # neighbor) pair so we never have to parse a Cypher map literal returned
  # by `collect({...})` in FalkorDB's verbose protocol.
  defp fetch_super_neighborhoods(_super_graph, [], _query_embedding), do: %{}

  defp fetch_super_neighborhoods(super_graph, ids, query_embedding) do
    ids = Enum.reject(ids, &is_nil/1)

    cypher = """
    MATCH (c:CanonicalEntity)-[:RELATES_TO]-(n:CanonicalEntity)
    WHERE c.id IN $ids
    RETURN c.id AS id, n.embedding AS embedding
    """

    case Magus.Graph.query(super_graph, cypher, %{ids: ids}) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.group_by(fn [id, _emb] -> id end, fn [_id, emb] -> emb end)
        |> Map.new(fn {id, embeddings} ->
          {id, compute_super_support(embeddings, query_embedding)}
        end)

      _ ->
        %{}
    end
  end

  defp compute_super_support(embeddings, query_embedding) do
    relevances =
      embeddings
      |> Enum.map(fn emb -> cosine_similarity(parse_embedding(emb), query_embedding) end)
      |> Enum.reject(&(&1 == 0.0))

    case relevances do
      [] ->
        1.0

      list ->
        avg = Enum.sum(list) / length(list)
        # Boost up to +1.0; never penalize below the neutral 1.0 baseline.
        1.0 + max(0.0, avg)
    end
  end

  defp enrich_with_sources(super_graph, canonical) do
    cid = Map.get(canonical, :id) || Map.get(canonical, "id")

    cypher = """
    MATCH (c:CanonicalEntity {id: $id})-[a:APPEARS_IN]->(s:SourcePointer)
    RETURN s.graph_name, a.mention_count, a.source_weight, a.latest_evidence_at, s.source_refs
    """

    enriched =
      case Magus.Graph.query(super_graph, cypher, %{id: cid}) do
        {:ok, %{rows: rows}} ->
          sources =
            Enum.map(rows, fn [graph_name, count, weight, ts, source_refs] ->
              %{
                graph_name: graph_name,
                mention_count: count |> parse_number(1.0) |> trunc(),
                source_weight: parse_number(weight, 1.0),
                latest_evidence_at: ts,
                source_refs: SourceRefs.decode(source_refs)
              }
            end)

          Map.put(canonical, :sources, sources)

        _ ->
          Map.put(canonical, :sources, [])
      end

    neighbors = fetch_canonical_neighbors(super_graph, cid)
    Map.put(enriched, :neighbors, neighbors)
  end

  # Pull 1-hop super-graph neighbors with the relationship metadata the
  # ranker does NOT use but the LLM benefits from seeing. In particular
  # `contested` and `predicate_breakdown` surface conflicting evidence
  # so the prompt can present "supports: 2 / contradicts: 1" instead of
  # silently parroting the modal predicate as ground truth.
  defp fetch_canonical_neighbors(_super_graph, nil), do: []

  defp fetch_canonical_neighbors(super_graph, cid) do
    cypher = """
    MATCH (c:CanonicalEntity {id: $id})-[r:RELATES_TO]-(n:CanonicalEntity)
    RETURN n.id, n.name, r.predicate, r.confidence, r.contested, r.predicate_breakdown
    """

    case Magus.Graph.query(super_graph, cypher, %{id: cid}) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [nid, name, pred, conf, contested, breakdown] ->
          %{
            id: nid,
            name: name,
            predicate: pred,
            confidence: parse_number(conf, 0.0),
            contested: parse_bool(contested),
            predicate_breakdown: decode_breakdown(breakdown)
          }
        end)

      _ ->
        []
    end
  end

  # FalkorDB returns booleans as raw atoms or as the literal strings
  # "true"/"false" depending on protocol mode. Coerce both shapes plus
  # nil (older edges that predate the contested flag) into a real bool.
  defp parse_bool(true), do: true
  defp parse_bool("true"), do: true
  defp parse_bool(_), do: false

  # The breakdown is stored as a JSON string property; FalkorDB has no
  # native map type for edge properties. nil/empty defaults to %{} so
  # consumers can pattern-match a real map either way.
  defp decode_breakdown(nil), do: %{}
  defp decode_breakdown(""), do: %{}

  defp decode_breakdown(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_breakdown(_), do: %{}

  # ---------------------------------------------------------------------------
  # Legacy iter2 per-Layer-1 fan-out (cold-start + drift fallback)
  # ---------------------------------------------------------------------------

  @doc false
  defp legacy_fan_out_search(actor, opts) do
    query_embedding = Keyword.fetch!(opts, :query_embedding)
    workspace_context = Keyword.get(opts, :workspace_context)
    limit = Keyword.get(opts, :limit, @default_result_limit)
    trust_tiers = Keyword.get(opts, :trust_tiers, @default_trust_tiers)

    graphs =
      actor
      |> AccessibleGraphs.for_actor(workspace_context: workspace_context)
      |> Enum.reject(&String.starts_with?(&1, "super:"))

    if graphs == [] do
      {:ok, []}
    else
      per_graph = fan_out(graphs, query_embedding, actor, trust_tiers)

      case aggregate_per_graph(per_graph) do
        {:ok, candidates_lists} ->
          ranked =
            candidates_lists
            |> List.flatten()
            |> Enum.sort_by(&Ranker.score/1, :desc)
            |> Enum.take(limit)

          {:ok, ranked}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc false
  # Public for unit testability only; not part of the public API.
  #
  # Aggregation policy:
  #
  #   * If at least one graph succeeded (even with an empty list), the
  #     successes win and errors are silently dropped.
  #   * If every graph errored AND at least one error is
  #     `:graph_unavailable`, surface `{:error, :all_graphs_unavailable}`
  #     so the caller can show a "temporarily unavailable" message.
  #   * Otherwise (all errored with non-`:graph_unavailable` reasons),
  #     fall back to `{:ok, []}`. This preserves the historical "no
  #     results" semantics for legitimate misses against empty graphs.
  def aggregate_per_graph(per_graph) when is_list(per_graph) do
    errors = Enum.filter(per_graph, fn {_g, r} -> match?({:error, _}, r) end)
    successes = Enum.filter(per_graph, fn {_g, r} -> match?({:ok, _}, r) end)

    cond do
      successes != [] ->
        lists = Enum.map(successes, fn {_g, {:ok, l}} -> l end)
        {:ok, lists}

      Enum.any?(errors, fn {_g, {:error, reason}} -> reason == :graph_unavailable end) ->
        {:error, :all_graphs_unavailable}

      true ->
        {:ok, []}
    end
  end

  defp fan_out(graphs, query_embedding, actor, trust_tiers) do
    graphs
    |> Task.async_stream(
      fn graph ->
        {graph, search_one_graph(graph, query_embedding, actor, trust_tiers)}
      end,
      max_concurrency: min(length(graphs), 8),
      timeout: @search_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} -> result
      _ -> {"<unknown>", {:error, :timeout}}
    end)
  end

  defp search_one_graph(graph_name, query_embedding, actor, trust_tiers) do
    graph_weight = GraphWeight.weight_for(graph_name, actor)
    allowed = Enum.map(trust_tiers, &Atom.to_string/1)

    case Magus.Graph.Vector.knn_search(
           graph_name,
           "Entity",
           "embedding",
           query_embedding,
           k: @default_per_graph_limit
         ) do
      {:ok, hits} ->
        hit_ids = Enum.map(hits, & &1.id)
        neighborhoods = fetch_neighborhoods(graph_name, hit_ids, query_embedding)

        candidates =
          Enum.flat_map(hits, fn hit ->
            if hit[:trust_tier] in allowed do
              support = Map.get(neighborhoods, hit.id, 1.0)
              [build_candidate(hit, graph_name, graph_weight, support)]
            else
              []
            end
          end)

        {:ok, candidates}

      {:error, _} = err ->
        err
    end
  end

  # Fetch 1-hop neighbors for the supplied hit ids and fold them into a
  # `%{hit_id => support}` map. Hits with no incident edges silently
  # default to the neutral support 1.0 in the caller via `Map.get/3`.
  #
  # The Cypher query returns one row per (hit, neighbor) pair so we
  # avoid FalkorDB's verbose protocol stringifying a Cypher map literal
  # produced by `collect({...})` (which would force us to write a parser
  # for the `[{embedding: <...>, conf: ...}]` string form). Aggregation
  # happens in Elixir where the shapes are well-typed.
  defp fetch_neighborhoods(_graph_name, [], _query_embedding), do: %{}

  defp fetch_neighborhoods(graph_name, hit_ids, query_embedding) do
    cypher = """
    MATCH (n:Entity)-[r:RELATES_TO]-(m:Entity)
    WHERE n.id IN $ids
    RETURN n.id AS id, m.embedding AS embedding, r.confidence AS conf
    """

    case Magus.Graph.query(graph_name, cypher, %{ids: hit_ids}) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.group_by(fn [id, _emb, _conf] -> id end, fn [_id, emb, conf] ->
          %{embedding: emb, conf: parse_number(conf, 0.5)}
        end)
        |> Map.new(fn {id, neighbors} ->
          {id, compute_support(neighbors, query_embedding)}
        end)

      _ ->
        %{}
    end
  end

  defp compute_support(neighbors, query_embedding) when is_list(neighbors) do
    relevances =
      Enum.map(neighbors, fn %{embedding: emb, conf: conf} ->
        cosine_similarity(parse_embedding(emb), query_embedding) * conf
      end)

    case relevances do
      [] ->
        1.0

      list ->
        avg = Enum.sum(list) / length(list)
        # Boost up to +1.0; never penalize below the neutral 1.0 baseline.
        1.0 + max(0.0, avg)
    end
  end

  defp compute_support(_, _), do: 1.0

  # FalkorDB serializes a stored `vecf32([...])` property as the string
  # literal "<1.000000, 0.000000, ...>" when read back through Cypher,
  # not as a list of floats. Be defensive and accept either shape (lists
  # would arrive only if FalkorDB changes its decoder in a future version).
  defp parse_embedding(nil), do: []
  defp parse_embedding(list) when is_list(list), do: list

  defp parse_embedding(s) when is_binary(s) do
    s
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn part ->
      case Float.parse(part) do
        {f, _} -> f
        :error -> 0.0
      end
    end)
  end

  defp parse_embedding(_), do: []

  defp cosine_similarity([], _), do: 0.0
  defp cosine_similarity(_, []), do: 0.0

  defp cosine_similarity(a, b) when length(a) == length(b) do
    dot = a |> Enum.zip(b) |> Enum.map(fn {x, y} -> x * y end) |> Enum.sum()
    na = :math.sqrt(a |> Enum.map(&(&1 * &1)) |> Enum.sum())
    nb = :math.sqrt(b |> Enum.map(&(&1 * &1)) |> Enum.sum())
    if na == 0 or nb == 0, do: 0.0, else: dot / (na * nb)
  end

  defp cosine_similarity(_, _), do: 0.0

  defp build_candidate(hit, graph_name, graph_weight, neighborhood_support) do
    # FalkorDB's `db.idx.vector.queryNodes` returns cosine DISTANCE
    # (0 = identical, 1 = orthogonal), but the ranker expects similarity
    # (1 = identical, 0 = orthogonal). Invert here so higher composite
    # scores correctly mean "more relevant".
    raw_score = parse_number(hit[:score], 1.0)
    similarity = max(0.0, 1.0 - raw_score)

    %{
      entity: %{
        name: hit[:name],
        type: hit[:type],
        trust_tier: parse_trust_tier(hit[:trust_tier]),
        confidence: parse_number(hit[:confidence], 0.5)
      },
      similarity: similarity,
      graph_name: graph_name,
      graph_weight: graph_weight,
      source_weight: parse_number(hit[:source_weight], 1.0),
      # Iteration 1: temporal recency is deferred. Treat all candidates
      # as "now" so the decay factor in Ranker.score/1 collapses to 1.0.
      latest_evidence_at: DateTime.utc_now(),
      neighborhood_support: neighborhood_support
    }
  end

  defp parse_trust_tier(nil), do: :evidence

  defp parse_trust_tier(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> :evidence
  end

  defp parse_trust_tier(value) when is_atom(value), do: value

  # FalkorDB's verbose Cypher protocol serializes numeric node properties
  # and procedure-yielded scalars (like the score column from
  # `db.idx.vector.queryNodes`) as strings, so we coerce them back to
  # floats here. Anything else falls back to the supplied default.
  defp parse_number(nil, default), do: default
  defp parse_number(n, _default) when is_number(n), do: n

  defp parse_number(s, default) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> default
    end
  end

  defp parse_number(_other, default), do: default
end
