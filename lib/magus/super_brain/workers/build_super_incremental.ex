defmodule Magus.SuperBrain.Workers.BuildSuperIncremental do
  @moduledoc """
  Incremental per-accessor super graph update.

  Processes only Episodes with `updated_at > super_row.last_built_at` and
  fuses their entities into the existing super graph via vector-index KNN
  matching. The same Postgres advisory lock used by `BuildSuperFull`
  serializes concurrent builds for the same accessor.

  On read-set drift (a workspace grant added or removed since the last
  full build) this enqueues a `BuildSuperFull` and exits with `:ok`. The
  drift itself is a signal, not a failure: the queued full build owns
  reconciliation.

  Cross-graph `:RELATES_TO` aggregation runs per-episode in the same
  delta path (iter4 Task 5). For each new episode the worker pulls Layer
  1 `:RELATES_TO` edges incident to the episode's entities, resolves
  both endpoint canonicals via their `SourcePointer` in the super graph,
  and upserts a `:CanonicalEntity-[:RELATES_TO]->:CanonicalEntity` edge
  when BOTH endpoints already exist. Edges whose endpoints are not yet
  materialized (e.g. a stale source graph not yet fused) defer to the
  nightly `BuildSuperFull`, which remains the authoritative reconciler
  for `appearance_count`, predicate, and trust-tier bookkeeping.

  ## FalkorDB gotchas

    * `Magus.Graph.Vector.knn_search/5` returns cosine DISTANCE in
      `:score`. Convert to similarity with `max(0.0, 1.0 - distance)`
      before applying the `0.95` merge threshold.
    * Numeric scalars come back as strings in verbose mode; coerce via
      `parse_number/2`.
    * Embeddings stored as `vecf32([...])` come back as the literal
      string `"<f1, f2, ...>"` when read through Cypher. `parse_embedding/1`
      accepts either shape.

  ## Canonical id formula

  Mirrors `BuildSuperFull.canonical_id_for/2` exactly so an incremental
  insert and a subsequent full rebuild agree on the canonical id space
  for the same `(name, type, normalized_subtype)` tuple in the same
  super graph.
  """

  use Oban.Worker,
    queue: :super_brain_extraction,
    max_attempts: 3,
    unique: [period: 30, fields: [:args]]

  alias Magus.SuperBrain.{
    AccessibleGraphs,
    AccessorLock,
    CanonicalId,
    EmbeddingConfig,
    Episode,
    FalkorValues,
    GraphWeight,
    Migration,
    Ontology,
    SourceRefs,
    SuperGraph
  }

  alias Magus.SuperBrain.Telemetry, as: SBTelemetry
  alias Magus.SuperBrain.Workers.BuildSuperFull

  require Ash.Query
  require Logger

  # Generous ceiling for one build while a pooled connection is pinned (see
  # `run_locked/1`). Realistic incremental deltas finish in seconds; this only
  # bounds a pathological batch or a FalkorDB stall. Well above the 15s default
  # that the previous transaction-scoped build kept tripping.
  @build_checkout_timeout :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    if Magus.SuperBrain.enabled?(),
      do: do_perform(job),
      else: {:cancel, :super_brain_disabled}
  end

  defp do_perform(%Oban.Job{args: args}) do
    accessor = parse_accessor(args)

    metadata = %{
      accessor_type: accessor.type,
      user_id: accessor.user_id,
      workspace_id: accessor.workspace_id
    }

    :telemetry.span(
      [:super_brain, :build_super_incremental],
      metadata,
      fn -> {run_locked(accessor), metadata} end
    )
  end

  # Pin ONE pooled connection for the whole build (`Repo.checkout`) so the
  # advisory lock's acquire and release run on the SAME session. The previous
  # `acquire_session/1` + `release_session/1` pair issued two independent
  # `Repo.query!` calls that the pool could route to different connections:
  # under backfill concurrency the lock taken on connection A was never
  # released (the unlock ran on B), so every later build blocked on
  # `pg_advisory_lock` until it tripped the 15s connection-checkout deadline
  # (the cascade of BuildSuperIncremental timeouts). Pinning the connection
  # also keeps the heavy FalkorDB fusion out of any Postgres transaction: the
  # checkout timeout covers it (the deadline is set ONCE per checkout, not per
  # inner query) and `super_brain_extraction` queue concurrency (4) keeps held
  # connections well under the pool size (10). `pg_try_advisory_lock` is
  # non-blocking: a build that loses the race skips instead of blocking, and
  # the winner covers the same episodes (last_built_at only advances on
  # success), so the delta is never dropped.
  defp run_locked(accessor) do
    Magus.Repo.checkout(
      fn ->
        if AccessorLock.try_acquire_session(accessor) do
          try do
            do_build(accessor)
          after
            :ok = AccessorLock.release_session(accessor)
          end
        else
          :ok
        end
      end,
      timeout: @build_checkout_timeout
    )
  end

  defp do_build(accessor) do
    with {:ok, super_row} <- fetch_super_graph_row(accessor),
         {:ok, user} <- load_user(accessor.user_id),
         current_read_set = compute_read_set(user, accessor),
         {:cont, :no_drift} <- maybe_drift(super_row, current_read_set, accessor),
         {:ok, new_episodes} <- fetch_new_episodes(super_row, current_read_set),
         :ok <- ensure_index(super_row.graph_name),
         :ok <- process_new_episodes(super_row.graph_name, new_episodes, user),
         :ok <- aggregate_relates_to_for_episodes(super_row.graph_name, new_episodes),
         {:ok, _} <- update_last_built_at(super_row, new_episodes) do
      :ok
    else
      # Drift enqueued a full rebuild; that build owns reconciliation, so this
      # run is a success rather than a failure.
      {:drift, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Accessor + lock
  # ---------------------------------------------------------------------------

  defp parse_accessor(args) do
    %{
      type: parse_accessor_type(args["accessor_type"]),
      user_id: args["user_id"],
      workspace_id: args["workspace_id"]
    }
  end

  defp parse_accessor_type("user"), do: :user
  defp parse_accessor_type("workspace"), do: :workspace
  defp parse_accessor_type(a) when a in [:user, :workspace], do: a

  # ---------------------------------------------------------------------------
  # SuperGraph row lookup
  # ---------------------------------------------------------------------------

  defp fetch_super_graph_row(accessor) do
    case SuperGraph
         |> filter_by_accessor(accessor)
         |> Ash.read_one(authorize?: false) do
      {:ok, %SuperGraph{} = row} -> {:ok, row}
      {:ok, nil} -> {:error, :no_super_graph_row}
      {:error, _} = err -> err
    end
  end

  # `is_nil/1` against a nullable uuid column; matches BuildSuperFull.
  defp filter_by_accessor(query, %{type: type, user_id: uid, workspace_id: nil}) do
    Ash.Query.filter(
      query,
      accessor_type == ^type and user_id == ^uid and is_nil(workspace_id)
    )
  end

  defp filter_by_accessor(query, %{type: type, user_id: uid, workspace_id: ws}) do
    Ash.Query.filter(
      query,
      accessor_type == ^type and user_id == ^uid and workspace_id == ^ws
    )
  end

  defp load_user(user_id) do
    Ash.get(Magus.Accounts.User, user_id, authorize?: false)
  end

  # ---------------------------------------------------------------------------
  # Drift detection
  # ---------------------------------------------------------------------------

  defp compute_read_set(user, accessor) do
    AccessibleGraphs.for_actor(user, workspace_context: accessor.workspace_id)
    |> Enum.reject(&String.starts_with?(&1, "super:"))
  end

  defp maybe_drift(super_row, current_read_set, accessor) do
    snapshot_graphs =
      super_row.read_set_snapshot
      |> Enum.map(fn entry ->
        Map.get(entry, "graph_name") || Map.get(entry, :graph_name)
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    if snapshot_graphs == Enum.sort(current_read_set) do
      {:cont, :no_drift}
    else
      SBTelemetry.drift_detected(%{
        accessor_type: accessor.type,
        user_id: accessor.user_id,
        workspace_id: accessor.workspace_id
      })

      _ = enqueue_full(accessor)
      {:drift, :ok}
    end
  end

  defp enqueue_full(accessor) do
    %{
      "accessor_type" => Atom.to_string(accessor.type),
      "user_id" => accessor.user_id,
      "workspace_id" => accessor.workspace_id
    }
    |> BuildSuperFull.new()
    |> Oban.insert()
  end

  # ---------------------------------------------------------------------------
  # Episode diff
  # ---------------------------------------------------------------------------

  defp fetch_new_episodes(super_row, current_read_set) do
    threshold = super_row.last_built_at || ~U[1970-01-01 00:00:00.000000Z]

    case Episode
         |> Ash.Query.filter(
           graph_name in ^current_read_set and
             status == :extracted and
             updated_at > ^threshold
         )
         |> Ash.read(authorize?: false) do
      {:ok, episodes} -> {:ok, episodes}
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Super-graph writes
  # ---------------------------------------------------------------------------

  defp ensure_index(graph_name) do
    case Magus.Graph.Vector.ensure_index(graph_name, "CanonicalEntity", "embedding",
           dim: EmbeddingConfig.dim(),
           similarity: :cosine
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} = err ->
        Logger.warning(
          "BuildSuperIncremental: failed to ensure vector index on #{graph_name}: #{inspect(reason)}"
        )

        err
    end
  end

  defp process_new_episodes(_super_graph, [], _user), do: :ok

  defp process_new_episodes(super_graph, episodes, user) do
    Enum.each(episodes, &process_episode_entities(super_graph, &1, user))
    :ok
  end

  # ---------------------------------------------------------------------------
  # Cross-graph RELATES_TO aggregation (iter4 Task 5)
  # ---------------------------------------------------------------------------

  # Trust tier precedence matches BuildSuperFull.@tier_order so the
  # incremental and nightly paths agree on the tier the canonical edge
  # carries.
  @tier_order %{"instruction" => 3, "evidence" => 2, "noise" => 1}

  @extractor_version "build_super_incremental@2026-05-29"

  defp aggregate_relates_to_for_episodes(_super_graph, []), do: :ok

  defp aggregate_relates_to_for_episodes(super_graph, episodes) do
    Enum.each(episodes, fn episode ->
      aggregate_relates_to_for_episode(super_graph, episode)
    end)

    :ok
  end

  defp aggregate_relates_to_for_episode(super_graph, episode) do
    source_graph = episode.graph_name

    # Pull Layer 1 RELATES_TO edges incident to entities created by THIS
    # episode. Both endpoints must be source-tagged to this episode so
    # we only see edges the extractor wrote in the same pass. Edges
    # touching pre-existing entities (HAS_ENTITY survivors) flow through
    # the source_id filter on at least one side because extract_base
    # tags every new RELATES_TO with the current episode_id (see
    # extract_base.ex:588).
    cypher = """
    MATCH (a:Entity)-[r:RELATES_TO {source_id: $sid}]->(b:Entity)
    RETURN a.id, b.id, r.predicate, r.confidence, r.trust_tier
    """

    case Magus.Graph.query(source_graph, cypher, %{sid: episode.id}) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.group_by(
          fn [a_id, b_id, _pred, _conf, _tier] -> {a_id, b_id} end,
          fn [_a, _b, pred, conf, tier] -> {pred, FalkorValues.parse_number(conf, 0.0), tier} end
        )
        |> Enum.each(fn {{a_id, b_id}, group} ->
          upsert_canonical_edge(super_graph, source_graph, a_id, b_id, group)
        end)

        :ok

      _ ->
        :ok
    end
  end

  defp upsert_canonical_edge(super_graph, source_graph, a_id, b_id, group) do
    with {:ok, from_canonical} when not is_nil(from_canonical) <-
           {:ok, lookup_canonical(super_graph, source_graph, a_id)},
         {:ok, to_canonical} when not is_nil(to_canonical) <-
           {:ok, lookup_canonical(super_graph, source_graph, b_id)},
         # iter5 Task 3.6: skip self-edges. A Layer 1 RELATES_TO whose
         # endpoints fuse into the same canonical would otherwise create
         # a canonical->itself loop on every incremental run.
         true <- from_canonical != to_canonical do
      incoming_predicates =
        group |> Enum.map(fn {p, _c, _t} -> p end) |> Enum.reject(&is_nil/1)

      predicate = FalkorValues.most_common(Enum.map(group, fn {p, _c, _t} -> p end))
      max_conf = group |> Enum.map(fn {_p, c, _t} -> c end) |> Enum.max(fn -> 0.0 end)

      max_tier =
        group
        |> Enum.map(fn {_p, _c, t} -> t end)
        |> Enum.reject(&is_nil/1)
        |> case do
          [] -> "evidence"
          tiers -> Enum.max_by(tiers, fn t -> Map.get(@tier_order, t, 0) end)
        end

      # Read existing breakdown + contested so we can merge incoming
      # predicates without losing prior counts. Decoding/encoding the
      # breakdown in Elixir keeps the Cypher path simple; the awkward
      # alternative is a `CASE WHEN` over a stringified JSON property.
      prior = fetch_edge_aggregation(super_graph, from_canonical, to_canonical)
      prior_breakdown = prior.breakdown
      incoming_breakdown = Enum.frequencies(incoming_predicates)

      merged_breakdown =
        Map.merge(prior_breakdown, incoming_breakdown, fn _k, a, b -> a + b end)

      predicate_breakdown_json = Jason.encode!(merged_breakdown)
      contested = prior.contested or contested?(merged_breakdown)

      _ =
        Magus.Graph.query(
          super_graph,
          """
          MATCH (from:CanonicalEntity {id: $from_id})
          MATCH (to:CanonicalEntity {id: $to_id})
          MERGE (from)-[r:RELATES_TO]->(to)
          ON CREATE SET r.predicate = $predicate,
                        r.confidence = $confidence,
                        r.appearance_count = 1,
                        r.trust_tier = $trust_tier,
                        r.source_graphs = [$source_graph],
                        r.extractor = $extractor,
                        r.contested = $contested,
                        r.predicate_breakdown = $predicate_breakdown
          ON MATCH SET r.appearance_count = coalesce(r.appearance_count, 1) + 1,
                       r.confidence = CASE
                                        WHEN r.confidence IS NULL OR $confidence > r.confidence
                                        THEN $confidence
                                        ELSE r.confidence
                                      END,
                       r.trust_tier = CASE
                                        WHEN r.trust_tier IS NULL
                                        THEN $trust_tier
                                        ELSE r.trust_tier
                                      END,
                       r.extractor = $extractor,
                       r.contested = $contested,
                       r.predicate_breakdown = $predicate_breakdown
          """,
          %{
            from_id: from_canonical,
            to_id: to_canonical,
            predicate: predicate,
            confidence: max_conf,
            trust_tier: max_tier,
            source_graph: source_graph,
            extractor: @extractor_version,
            contested: contested,
            predicate_breakdown: predicate_breakdown_json
          }
        )

      :ok
    else
      # Either endpoint canonical missing in the super graph: defer this
      # edge to the nightly full rebuild rather than fabricating a
      # phantom canonical mid-incremental.
      _ ->
        :ok
    end
  end

  # Read the prior aggregation state of the canonical edge so we can
  # merge incoming predicates and flip `contested` when the new payload
  # introduces the opposite of an already-recorded predicate.
  defp fetch_edge_aggregation(super_graph, from_id, to_id) do
    cypher = """
    MATCH (from:CanonicalEntity {id: $from_id})-[r:RELATES_TO]->(to:CanonicalEntity {id: $to_id})
    RETURN r.predicate_breakdown, r.contested
    LIMIT 1
    """

    case Magus.Graph.query(super_graph, cypher, %{from_id: from_id, to_id: to_id}) do
      {:ok, %{rows: [[bd, contested] | _]}} ->
        %{
          breakdown: decode_breakdown(bd),
          contested: contested_truthy?(contested)
        }

      _ ->
        %{breakdown: %{}, contested: false}
    end
  end

  defp decode_breakdown(nil), do: %{}
  defp decode_breakdown(""), do: %{}

  defp decode_breakdown(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_breakdown(_), do: %{}

  # FalkorDB returns booleans as the strings "true"/"false" in verbose
  # mode; accept either form so a previously-set contested edge survives
  # the round trip.
  defp contested_truthy?(true), do: true
  defp contested_truthy?("true"), do: true
  defp contested_truthy?(_), do: false

  defp contested?(breakdown_map) when is_map(breakdown_map) do
    contradicting = Ontology.contradicting_predicates()
    keys = Map.keys(breakdown_map)

    Enum.any?(keys, fn pred ->
      opposite = Map.get(contradicting, pred)
      opposite != nil and opposite in keys
    end)
  end

  # Look up the CanonicalEntity that this Layer 1 entity id has been
  # fused into via its SourcePointer. Returns nil when no canonical
  # exists yet (defers the edge to nightly).
  defp lookup_canonical(super_graph, source_graph, entity_id) do
    cypher = """
    MATCH (c:CanonicalEntity)-[:APPEARS_IN]->(s:SourcePointer {graph_name: $g, source_node_id: $eid})
    RETURN c.id
    LIMIT 1
    """

    case Magus.Graph.query(super_graph, cypher, %{g: source_graph, eid: entity_id}) do
      {:ok, %{rows: [[cid] | _]}} -> cid
      _ -> nil
    end
  end

  defp process_episode_entities(super_graph, episode, user) do
    source_graph = episode.graph_name

    cypher = """
    MATCH (e:Entity {source_id: $sid})
    RETURN e.id, e.name, e.type, e.subtype, e.normalized_subtype,
           e.embedding, e.confidence, e.trust_tier
    """

    case Magus.Graph.query(source_graph, cypher, %{sid: episode.id}) do
      {:ok, %{rows: rows}} ->
        Enum.each(rows, fn row ->
          fuse_entity_into_super(super_graph, source_graph, row, user)
        end)

      _ ->
        :ok
    end
  end

  defp fuse_entity_into_super(
         super_graph,
         source_graph,
         [
           id,
           name,
           type,
           subtype,
           nsubtype,
           emb,
           _conf,
           tier
         ],
         user
       ) do
    parsed_emb = FalkorValues.parse_embedding(emb)

    canonical_id =
      find_or_create_canonical(
        super_graph,
        name,
        type,
        subtype,
        nsubtype,
        parsed_emb,
        tier
      )

    pointer_id =
      :crypto.hash(:sha256, "#{source_graph}|#{id}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    # Recompute the COMPLETE page-level ref set for this entity (it may appear
    # in pages beyond the episode that triggered this incremental run), so the
    # stored value is idempotent and matches what a full rebuild would write.
    source_refs = SourceRefs.encode(source_refs_for(source_graph, id))

    _ =
      Magus.Graph.upsert_node(super_graph, "SourcePointer", %{
        id: pointer_id,
        graph_name: source_graph,
        source_node_id: id,
        source_refs: source_refs
      })

    # Mirror BuildSuperFull: per-source weight is `GraphWeight.weight_for/2`
    # so an incremental insert and a subsequent full rebuild agree on the
    # APPEARS_IN edge weight. A hardcoded 1.0 here would silently override
    # any per-accessor weight override the next nightly recomputes from.
    source_weight = GraphWeight.weight_for(source_graph, user)

    _ =
      Magus.Graph.upsert_edge(
        super_graph,
        %{
          from_label: "CanonicalEntity",
          from_id: canonical_id,
          to_label: "SourcePointer",
          to_id: pointer_id
        },
        "APPEARS_IN",
        %{
          graph_name: source_graph,
          source_node_id: id,
          mention_count: 1,
          latest_evidence_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          source_weight: source_weight
        }
      )

    :ok
  end

  # Complete page-level provenance for a Layer 1 entity: every Episode
  # (brain page, draft, file, ...) whose HAS_ENTITY points at it, as
  # `"resource_type|resource_id"` strings. Mirrors the OPTIONAL MATCH used by
  # `BuildSuperFull.pull_one_graph/1` so both builders write identical
  # `source_refs`.
  defp source_refs_for(source_graph, entity_id) do
    cypher = """
    MATCH (ep:Episode)-[:HAS_ENTITY]->(e:Entity {id: $eid})
    RETURN collect(DISTINCT ep.resource_type + '|' + ep.resource_id) AS refs
    """

    case Magus.Graph.query(source_graph, cypher, %{eid: entity_id}) do
      {:ok, %{rows: [[refs] | _]}} -> SourceRefs.from_pair_strings(refs)
      _ -> []
    end
  end

  # Wave 2: symmetric ON MATCH SET. Pre-Wave-2 the KNN-hit path returned
  # the existing canonical id and skipped any property update, so a
  # curated `:instruction` incremental fusing into an existing
  # `:evidence` canonical kept the `:evidence` tier until the next
  # nightly. trust_tier, source_count, and embedding all silently
  # diverged from what the next BuildSuperFull would compute.
  #
  # Now: read the existing canonical's `(source_count, embedding,
  # trust_tier)`, compute the promoted values, and write them back
  # alongside the create. Since canonical_id is now purely a function
  # of `(super_graph, type, normalized_subtype)` (Wave 2 Task 2.1), the
  # KNN match is only used to confirm an entity belongs in the same
  # bucket; the hash key already collides.
  defp find_or_create_canonical(super_graph, name, type, subtype, nsubtype, embedding, tier) do
    canonical_id = CanonicalId.for(super_graph, type, nsubtype, name)

    case fetch_canonical_state(super_graph, canonical_id) do
      {:ok, existing} ->
        promote_canonical(super_graph, canonical_id, existing, embedding, tier)
        canonical_id

      :none ->
        create_canonical(
          super_graph,
          canonical_id,
          name,
          type,
          subtype,
          nsubtype,
          embedding,
          tier
        )
    end
  end

  defp fetch_canonical_state(super_graph, canonical_id) do
    cypher = """
    MATCH (c:CanonicalEntity {id: $id})
    RETURN c.source_count, c.embedding, c.trust_tier
    LIMIT 1
    """

    case Magus.Graph.query(super_graph, cypher, %{id: canonical_id}) do
      {:ok, %{rows: [[sc, emb, tt] | _]}} ->
        {:ok,
         %{
           source_count: FalkorValues.parse_number(sc, 1.0),
           embedding: FalkorValues.parse_embedding(emb),
           trust_tier: tt
         }}

      _ ->
        :none
    end
  end

  # Promote the existing canonical with:
  #   - trust_tier = max(existing, incoming) per @tier_order
  #   - source_count = existing + 1
  #   - embedding = running mean (size-weighted by source_count)
  #
  # The running-mean formula uses the OLD source_count as the weight on
  # the existing embedding so the result equals the average of N+1
  # equally-weighted vectors. Pre-Wave-2 the embedding was first-write-
  # wins, which silently drifted from the from-scratch average.
  defp promote_canonical(super_graph, canonical_id, existing, incoming_embedding, incoming_tier) do
    new_source_count = existing.source_count + 1
    new_tier = max_tier(existing.trust_tier, incoming_tier)
    new_embedding = running_mean(existing.embedding, existing.source_count, incoming_embedding)

    props = %{
      source_count: new_source_count,
      trust_tier: new_tier || "evidence",
      last_evidence_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      migration_marker: Migration.canonical_version()
    }

    props =
      if new_embedding != [] do
        Map.put(props, :embedding, new_embedding)
      else
        props
      end

    _ = Magus.Graph.upsert_node(super_graph, "CanonicalEntity", Map.put(props, :id, canonical_id))
    :ok
  end

  defp max_tier(nil, b), do: b
  defp max_tier(a, nil), do: a

  defp max_tier(a, b) do
    if Map.get(@tier_order, a, 0) >= Map.get(@tier_order, b, 0), do: a, else: b
  end

  # `(existing * old_n + incoming) / (old_n + 1)` element-wise. Skips
  # the update when either vector is empty so we never write a malformed
  # embedding back; the next nightly will reconcile.
  defp running_mean([], _old_n, incoming), do: incoming
  defp running_mean(existing, _old_n, []) when is_list(existing), do: existing

  defp running_mean(existing, old_n, incoming)
       when is_list(existing) and is_list(incoming) and length(existing) == length(incoming) do
    old_n = max(old_n, 1.0)
    denom = old_n + 1.0

    Enum.zip(existing, incoming)
    |> Enum.map(fn {e, i} -> (e * old_n + i) / denom end)
  end

  defp running_mean(_existing, _old_n, _incoming), do: []

  defp create_canonical(
         super_graph,
         canonical_id,
         name,
         type,
         subtype,
         nsubtype,
         embedding,
         tier
       ) do
    props =
      %{
        id: canonical_id,
        name: name,
        primary_type: type || "concept",
        subtype: subtype,
        normalized_subtype: nsubtype,
        embedding: embedding,
        trust_tier: tier || "evidence",
        importance_score: 1.0,
        source_count: 1,
        last_evidence_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        built_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        migration_marker: Migration.canonical_version()
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    _ = Magus.Graph.upsert_node(super_graph, "CanonicalEntity", props)
    canonical_id
  end

  # ---------------------------------------------------------------------------
  # Last-built bookkeeping
  # ---------------------------------------------------------------------------

  defp update_last_built_at(super_row, []) do
    {:ok, super_row}
  end

  defp update_last_built_at(super_row, _episodes) do
    Ash.update(
      super_row,
      %{
        last_build_duration_ms: 0,
        canonical_entity_count: super_row.canonical_entity_count,
        canonical_edge_count: super_row.canonical_edge_count,
        read_set_snapshot: super_row.read_set_snapshot
      },
      action: :mark_built,
      authorize?: false
    )
  end
end
