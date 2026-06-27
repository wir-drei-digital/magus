defmodule Magus.SuperBrain.Workers.BuildSuperFull do
  @moduledoc """
  Full rebuild of a single accessor's Layer 2 super graph.

  An "accessor" is the tuple `(type, user_id, workspace_id)` (where
  `type` is `:user` or `:workspace`). Each accessor has exactly one super
  graph, named via `Magus.SuperBrain.AccessibleGraphs.super_graph_for/2`,
  whose contents are derived deterministically from the Layer 1 graphs
  the accessor can read.

  ## Staged build (iter5 Task 3.1)

  Pre-iter5 the worker did three things that did not survive partial
  failures:

    1. Wrapped the entire multi-minute pipeline in `Repo.transaction`,
       holding a Postgres connection for the whole build and risking
       `idle_in_transaction_timeout` plus pool starvation.
    2. Dropped the live super graph BEFORE building, so a crash between
       the drop and `mark_built` left users with an empty graph until
       `SuperGraphMaintenance` reran hours later.
    3. Swallowed FalkorDB write errors via `_ = Magus.Graph.query(...)`,
       so a partial write produced a "successful" build with quietly
       missing nodes.

  The new flow:

    1. Acquire a session-scoped `pg_advisory_lock` (via
       `AccessorLock.acquire_session/1`) OUTSIDE any Repo.transaction.
       The lock is released in an `after` block so a crash cannot
       deadlock the next build.
    2. Mark the existing `SuperGraph` row `:building` in a SHORT
       transaction (a few queries).
    3. Build into a staging graph named `<live_name>:building`. The
       live graph keeps serving queries the entire time.
    4. Track FalkorDB write errors with `Magus.SuperBrain.WriteCounter`.
       If `errors / total > @write_error_threshold` the build fails
       and the staging graph is dropped without swapping.
    5. On success, swap staging into live with `swap_into_live/2`:
       `GRAPH.DELETE` the (old) live graph, then `GRAPH.COPY` staging
       to live, then `GRAPH.DELETE` staging. The window where the live
       graph is missing is bounded to two FalkorDB commands (typically
       under a second) instead of the multi-minute exposure of the
       pre-iter5 design.
    6. On failure, `mark_failed_safe/2` runs in a FRESH top-level
       transaction so the status flip survives independent of the
       inner work. The live graph is untouched.

  ## Swap strategy

  FalkorDB v4 exposes `GRAPH.COPY src dst` (clone) but no atomic
  "rename or overwrite" primitive. The only way to overwrite an
  existing graph name with new contents is the delete-then-copy
  sequence used here. Queries that arrive between the delete and the
  copy of the swap will see "empty graph" (or
  `:graph_unavailable` from the circuit breaker). We accept this
  tiny exposure window as the cost of avoiding the much worse
  hours-long empty-graph window that the pre-iter5 drop-then-build
  pattern could produce on a crash.

  ## Original algorithm (unchanged)

    1. Compute the read-set via `AccessibleGraphs.for_actor/2`,
       then reject any `super:`-prefixed names (Layer 1 only).
    2. Ensure the vector index on `:CanonicalEntity.embedding`
       exists on the staging graph.
    3. Pull every `:Entity` node from each Layer 1 graph in the
       read-set.
    4. Group entities by `(type, normalized_subtype, name)` (the same
       `CanonicalId.name_key/1` that feeds the canonical id), so distinct
       names stay distinct and same-named instances across graphs fuse.
    5. Write one `:CanonicalEntity` per group, plus one
       `:SourcePointer` per source-entity instance with an
       `:APPEARS_IN` edge from canonical to pointer.
    6. Aggregate `:RELATES_TO` edges from Layer 1 into the super
       graph between the corresponding canonical nodes.
    7. Compute `importance_score` per canonical via
       `source_count * sum(source_weight * log(1 + mention_count))`.
       This is raw popularity only; the trust-tier multiplier is
       applied once at query time in `Magus.SuperBrain.Retrieval`.
    8. Swap staging into live (see above).
    9. Update the `SuperGraph` row to `:ok` with the read-set
       snapshot, counts, and duration.

  ## FalkorDB gotchas

    * Numeric scalars (counts, scores, properties) come back as
      strings in verbose mode. `parse_number/2` coerces them back to
      floats.
    * Embeddings stored via `vecf32([...])` come back as the literal
      string `"<f1, f2, ...>"`, not a list. `parse_embedding/1`
      parses either shape.
    * The cosine "score" yielded by `db.idx.vector.queryNodes` is a
      DISTANCE, not a similarity. This worker only computes cosine
      manually (no procedure call), so the threshold is applied
      directly to true similarity.
  """

  use Oban.Worker,
    queue: :super_brain_extraction,
    max_attempts: 3,
    unique: [period: 60, fields: [:args]]

  alias Magus.SuperBrain.AccessibleGraphs
  alias Magus.SuperBrain.AccessorLock
  alias Magus.SuperBrain.CanonicalId
  alias Magus.SuperBrain.EdgeAggregation
  alias Magus.SuperBrain.EmbeddingConfig
  alias Magus.SuperBrain.FalkorValues
  alias Magus.SuperBrain.GraphWeight
  alias Magus.SuperBrain.Migration
  alias Magus.SuperBrain.SourceRefs
  alias Magus.SuperBrain.SuperGraph

  require Ash.Query
  require Logger

  @extractor_version "build_super_worker@2026-05-25"

  # Maximum fraction of FalkorDB write attempts allowed to error before
  # the build refuses to swap staging into live. The threshold is
  # intentionally generous: transient sporadic errors are normal; a
  # systemic problem (bad index, disk full, malformed data) will easily
  # exceed 5% and is what we want to catch.
  @write_error_threshold 0.05

  # FalkorDB's `GRAPH.COPY` forks the server process to take a consistent
  # snapshot of the source graph (much like Redis `BGSAVE`). Under memory
  # pressure the `fork()` syscall can transiently fail ("could not fork",
  # i.e. ENOMEM/EAGAIN), which is common in CI containers with conservative
  # memory-overcommit settings. The failure is point-in-time, so a short
  # bounded retry clears it without leaving the swap half-done: after step 1
  # dropped live, the source (staging) still exists and the destination
  # (live) does not, so re-issuing the COPY is safe and idempotent.
  @copy_max_retries 5
  @copy_retry_base_ms 100

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    if Magus.SuperBrain.enabled?(),
      do: do_perform(job),
      else: {:cancel, :super_brain_disabled}
  end

  defp do_perform(%Oban.Job{args: args}) do
    started_at = System.monotonic_time(:millisecond)
    accessor = parse_accessor(args)

    metadata = %{
      accessor_type: accessor.type,
      user_id: accessor.user_id,
      workspace_id: accessor.workspace_id
    }

    :ok = AccessorLock.acquire_session(accessor)

    try do
      result =
        :telemetry.span(
          [:super_brain, :build_super_full],
          metadata,
          fn ->
            inner = do_build(accessor, started_at)
            {inner, metadata}
          end
        )

      case result do
        {:error, reason} ->
          # The staged build owns its own staging-graph cleanup on
          # failure; the only Postgres update left is the status flip.
          # Run it in a fresh transaction so it survives independent
          # of any inner failure mode (the iter5 Wave 1 Task 1.2 fix).
          mark_failed_safe(accessor, reason)
          {:error, reason}

        other ->
          other
      end
    after
      # Pair with `acquire_session/1`. Run unconditionally so a crash
      # cannot leak the lock and deadlock the next build for this
      # accessor.
      :ok = AccessorLock.release_session(accessor)
    end
  end

  # ---------------------------------------------------------------------------
  # Pipeline
  # ---------------------------------------------------------------------------

  # Orchestrates the staged build:
  #
  #   1. Touch the `SuperGraph` row (`mark_building`) in a short
  #      transaction.
  #   2. Compute the read-set and clear any stale staging graph from a
  #      previous failed run.
  #   3. Build into staging (the long-running FalkorDB work; runs
  #      entirely outside any Postgres transaction).
  #   4. Validate the write error rate.
  #   5. Swap staging into live.
  #   6. Mark the row `:ok` (short transaction).
  #
  # On any error from steps 2 through 5 the staging graph is dropped
  # (best-effort) and the error propagates upward; the live graph is
  # NEVER touched on the failure path.
  defp do_build(accessor, started_at) do
    with {:ok, super_row} <- prepare_row(accessor),
         {:ok, user} <- load_user(accessor.user_id) do
      live_name = super_row.graph_name
      staging_name = building_graph_name(live_name)
      read_set = compute_read_set(user, accessor)

      # Belt-and-suspenders: a previous failed run may have left a
      # staging graph behind. Drop it before reusing the name.
      _ = Magus.Graph.drop(staging_name)

      case stage_build(staging_name, read_set, user) do
        {:ok, %{canonicals: canonical_count, edges: edge_count, writes: write_stats}} ->
          adjusted = maybe_override_write_stats(write_stats)

          with :ok <- check_write_errors(staging_name, adjusted),
               :ok <- swap_into_live(staging_name, live_name),
               {:ok, _} <-
                 mark_built(super_row, read_set, canonical_count, edge_count, started_at) do
            :ok
          else
            {:error, reason} ->
              # Don't leave staging behind on swap/mark_built failure;
              # next build would observe it. The live graph already
              # swapped (if we got past `swap_into_live`) or remains
              # untouched (if we did not).
              _ = Magus.Graph.drop(staging_name)
              {:error, reason}
          end

        {:error, reason} ->
          # Staging-only failure: live graph untouched, staging cleaned
          # up so the next attempt starts fresh.
          _ = Magus.Graph.drop(staging_name)
          {:error, reason}
      end
    end
  end

  # Test-only: lets the write-error threshold test force the build to
  # report a write rate above the threshold without having to mock
  # FalkorDB. In production the config key is unset and the original
  # stats pass through unchanged.
  defp maybe_override_write_stats(stats) do
    case Application.get_env(:magus, __MODULE__, [])[:test_force_write_stats] do
      %{total: _, errors: _} = forced -> forced
      _ -> stats
    end
  end

  # Wraps the row-lifecycle updates in a short transaction. These are
  # cheap Postgres queries; the long-running FalkorDB work happens
  # outside this block.
  defp prepare_row(accessor) do
    Magus.Repo.transaction(fn ->
      with {:ok, super_row} <- ensure_super_graph_row(accessor),
           {:ok, super_row} <- mark_building(super_row) do
        super_row
      else
        {:error, reason} ->
          Magus.Repo.rollback(reason)
      end
    end)
  end

  # Returns
  #   {:ok, %{canonicals: integer, edges: integer, writes: %{total, errors}}}
  #
  # on success, `{:error, reason}` on a step that returns an explicit
  # error tuple (vector-index creation, importance-score query). Per-node
  # and per-edge write failures are absorbed into `writes` and judged in
  # bulk by `check_write_errors/2`.
  defp stage_build(staging_name, read_set, user) do
    with :ok <- ensure_index(staging_name),
         {:ok, layer1_entities} <- pull_layer1_entities(read_set) do
      clusters = cluster_entities(layer1_entities)

      writes_canonicals = write_canonicals(staging_name, clusters, user)
      writes_edges = aggregate_relates_to(staging_name, clusters, read_set)

      with :ok <- compute_importance_scores(staging_name),
           :ok <- maybe_inject_test_failure(:after_staging_writes) do
        {:ok,
         %{
           canonicals: writes_canonicals.canonical_count,
           edges: writes_edges.edge_count,
           writes: combine_writes(writes_canonicals.writes, writes_edges.writes)
         }}
      else
        {:error, _} = err -> err
      end
    end
  end

  # Test-only failure injection. Production callers set nothing in the
  # `:test_inject_failure_at` Application env so this is a constant
  # `:ok` in production. Tests can set the value to a stage atom (e.g.
  # `:after_staging_writes`) to force the build to fail at that point
  # without having to mock FalkorDB.
  defp maybe_inject_test_failure(stage) do
    case Application.get_env(:magus, __MODULE__, [])[:test_inject_failure_at] do
      ^stage -> {:error, {:test_injected, stage}}
      _ -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Accessor + staging-name derivation
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

  @doc false
  # Exposed for tests via `Magus.SuperBrain.Workers.BuildSuperFull.building_graph_name/1`.
  def building_graph_name(live_name) when is_binary(live_name) do
    live_name <> ":building"
  end

  # ---------------------------------------------------------------------------
  # SuperGraph row lifecycle
  # ---------------------------------------------------------------------------

  defp ensure_super_graph_row(accessor) do
    graph_name = graph_name_for(accessor)

    case SuperGraph
         |> filter_by_accessor(accessor)
         |> Ash.read_one(authorize?: false) do
      {:ok, %SuperGraph{} = row} ->
        {:ok, row}

      {:ok, nil} ->
        SuperGraph
        |> Ash.create(
          %{
            accessor_type: accessor.type,
            user_id: accessor.user_id,
            workspace_id: accessor.workspace_id,
            graph_name: graph_name,
            last_build_status: :building
          },
          authorize?: false,
          return_notifications?: true
        )
        |> drop_notifications()

      {:error, _} = err ->
        err
    end
  end

  defp graph_name_for(%{type: :user, user_id: uid}), do: "super:user:#{uid}"

  defp graph_name_for(%{type: :workspace, user_id: uid, workspace_id: ws}),
    do: "super:workspace:#{ws}:#{uid}"

  # Use `is_nil/1` against a nullable `workspace_id` (the `== nil` form
  # always returns false against an Ecto-typed uuid column).
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

  defp mark_building(super_row) do
    super_row
    |> Ash.update(%{}, action: :mark_building, authorize?: false, return_notifications?: true)
    |> drop_notifications()
  end

  # `prepare_row/1` runs `ensure_super_graph_row` and `mark_building` inside a
  # `Repo.transaction`, so Ash cannot dispatch their notifications while the
  # data layer is still in a transaction: it returns them as "unsent" and logs
  # a "Missed N notifications in action ..." warning for each. `SuperGraph`
  # declares no notifiers (the `:mark_*` actions carry no `pub_sub`), so those
  # notifications have no subscribers. We pass `return_notifications?: true`
  # and discard them, which silences the warning without changing behaviour:
  # the same pattern as `ExtractBase.drop_notifications/1`. The post-transaction
  # `mark_built` / `mark_failed` updates run OUTSIDE any outer transaction, so
  # Ash dispatches their notifications normally and they need no such handling.
  defp drop_notifications({:ok, record, _notifications}), do: {:ok, record}
  defp drop_notifications(other), do: other

  defp load_user(user_id) do
    Ash.get(Magus.Accounts.User, user_id, authorize?: false)
  end

  # ---------------------------------------------------------------------------
  # Read-set + graph bootstrap
  # ---------------------------------------------------------------------------

  # Sorted so the read-set order is deterministic across runs. Otherwise
  # the order of per-graph pulls (and thus the cluster aggregator's
  # entity arrival order) would drift run-to-run, which the Wave 2
  # convergence test forbids.
  defp compute_read_set(user, accessor) do
    AccessibleGraphs.for_actor(user, workspace_context: accessor.workspace_id)
    |> Enum.reject(&String.starts_with?(&1, "super:"))
    |> Enum.sort()
  end

  defp ensure_index(graph_name) do
    case Magus.Graph.Vector.ensure_index(graph_name, "CanonicalEntity", "embedding",
           dim: EmbeddingConfig.dim(),
           similarity: :cosine
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} = err ->
        Logger.warning(
          "BuildSuperFull: failed to ensure vector index on #{graph_name}: #{inspect(reason)}"
        )

        err
    end
  end

  # ---------------------------------------------------------------------------
  # Pull Layer 1 entities
  # ---------------------------------------------------------------------------

  defp pull_layer1_entities(read_set) do
    # Accumulate as a list of lists (`[entities | acc]`) then flatten once
    # at the end. The previous shape used `acc ++ entities`, which is
    # O(N^2) over the number of source graphs because `++` walks the LHS
    # every iteration; for a large read-set that quickly dominates the
    # build cost. The order of the final list is not observable: the
    # caller groups entities by `(type, normalized_subtype)` and clusters
    # within each bucket.
    result =
      Enum.reduce_while(read_set, {:ok, []}, fn graph_name, {:ok, acc} ->
        case pull_one_graph(graph_name) do
          {:ok, entities} ->
            {:cont, {:ok, [entities | acc]}}

          # A graph that hasn't been written to yet returns an error; treat
          # it as empty so a brand-new user with no extractions builds an
          # empty (but valid) super graph rather than failing the job.
          {:error, _reason} ->
            {:cont, {:ok, acc}}
        end
      end)

    case result do
      {:ok, chunks} -> {:ok, List.flatten(chunks)}
      other -> other
    end
  end

  defp pull_one_graph(graph_name) do
    # `ORDER BY e.id ASC` makes the row order stable. The downstream
    # clustering step's reduce is order-sensitive: the first entity in a
    # bucket seeds the first cluster and every subsequent candidate
    # checks clusters in the order they were created. Without a sort
    # FalkorDB returns rows in storage order, which can drift across
    # rebuilds and break Wave 2 property-equality.
    # `refs` denormalizes the page-level provenance: every Episode
    # (brain page, draft, file, ...) whose HAS_ENTITY points at this entity,
    # as `"resource_type|resource_id"` strings. OPTIONAL MATCH keeps entities
    # with no episode (collect drops the resulting nulls). See SourceRefs.
    cypher = """
    MATCH (e:Entity)
    OPTIONAL MATCH (ep:Episode)-[:HAS_ENTITY]->(e)
    WITH e, collect(DISTINCT ep.resource_type + '|' + ep.resource_id) AS refs
    RETURN e.id, e.name, e.type, e.subtype, e.normalized_subtype,
           e.embedding, e.confidence, e.trust_tier, e.extractor, refs
    ORDER BY e.id ASC
    """

    case Magus.Graph.query(graph_name, cypher, %{}) do
      {:ok, %{rows: rows}} ->
        entities =
          Enum.map(rows, fn [id, name, type, subtype, nsub, emb, conf, tier, extractor, refs] ->
            %{
              source_graph: graph_name,
              id: id,
              name: name,
              type: type,
              subtype: subtype,
              normalized_subtype: nsub,
              embedding: FalkorValues.parse_embedding(emb),
              confidence: FalkorValues.parse_number(conf, 0.0),
              trust_tier: tier,
              extractor: extractor,
              source_refs: SourceRefs.from_pair_strings(refs)
            }
          end)

        {:ok, entities}

      {:error, _} = err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Cross-graph clustering
  # ---------------------------------------------------------------------------

  # Group entities into canonicals by `(type, normalized_subtype, name_key)`.
  # This MUST key on the same `CanonicalId.name_key/1` the id hash uses so the
  # full rebuild and the incremental path (which keys each entity by its OWN
  # name) converge on the same canonical id. Same-named instances across
  # graphs fuse into one canonical; distinct names stay distinct. Different-
  # named ALIASES ("Daniel" vs "Daniel Smith") are intentionally NOT merged
  # here; that is deferred to a future LLM-judge fusion pass.
  #
  # Sorted by the group key so the cluster order is deterministic across
  # rebuilds (the Wave 2 convergence test forbids run-to-run drift).
  defp cluster_entities(entities) do
    entities
    |> Enum.group_by(fn e ->
      {e.type, e.normalized_subtype, CanonicalId.name_key(e.name)}
    end)
    |> Enum.sort_by(fn {key, _group} -> key end)
    |> Enum.map(fn {_key, group} -> group end)
  end

  # ---------------------------------------------------------------------------
  # CanonicalEntity + SourcePointer writes
  # ---------------------------------------------------------------------------

  defp write_canonicals(super_graph, clusters, actor) do
    Enum.reduce(clusters, %{canonical_count: 0, writes: empty_writes()}, fn cluster, acc ->
      canonical_id = canonical_id_for(super_graph, cluster)

      case write_canonical(super_graph, canonical_id, cluster) do
        {:ok, _} ->
          appears_writes =
            Enum.reduce(cluster, empty_writes(), fn instance, w_acc ->
              w =
                write_source_pointer_and_appears_in(
                  super_graph,
                  canonical_id,
                  instance,
                  actor
                )

              combine_writes(w_acc, w)
            end)

          %{
            canonical_count: acc.canonical_count + 1,
            writes:
              combine_writes(
                acc.writes,
                combine_writes(record_success(empty_writes()), appears_writes)
              )
          }

        {:error, reason} ->
          Logger.warning(
            "BuildSuperFull: failed to write CanonicalEntity in #{super_graph}: #{inspect(reason)}"
          )

          %{
            canonical_count: acc.canonical_count,
            writes: combine_writes(acc.writes, record_failure(empty_writes()))
          }
      end
    end)
  end

  # Canonical id formula delegates to `Magus.SuperBrain.CanonicalId.for/4`
  # so the BuildSuperFull and BuildSuperIncremental paths converge on the
  # SAME canonical id for the same `(super_graph, type, normalized_subtype,
  # name_key)` tuple. The name IS folded into the hash (via
  # `CanonicalId.name_key/1`): distinct names get distinct canonicals, while
  # same-named instances across graphs fuse. Different-named aliases
  # ("Daniel" vs "Daniel Smith") therefore stay separate until a future
  # LLM-judge fusion pass.
  #
  # Note: the canonical id MUST be invariant under the staging vs live
  # graph name (so the swap does not invalidate retrieval caches). We
  # derive it from the LIVE name (with `:building` stripped) so that
  # `canonical_id_for/2` inside the staging build agrees with what
  # `BuildSuperIncremental` will compute later against the live graph.
  defp canonical_id_for(super_graph, cluster) do
    head = List.first(cluster) || %{}
    name_hint = pick_canonical_name(cluster)
    canonical_graph = String.replace_suffix(super_graph, ":building", "")

    CanonicalId.for(
      canonical_graph,
      Map.get(head, :type),
      Map.get(head, :normalized_subtype),
      name_hint
    )
  end

  # Deterministic canonical-name picker: longest name in the cluster
  # wins, tie-broken by the LOWEST entity id (alphanumerically). Using
  # `confidence` as a tie-break (the pre-Wave-2 shape) was non-deterministic
  # in practice: confidence is a float that varies with extractor
  # randomness and clusters built run-to-run from the same Layer 1 input
  # could pick different winners. Entity ids are stable hashes derived
  # from `(graph_name, name)`, so the lowest-id tie-break is the strongest
  # determinism guarantee available at this layer.
  defp pick_canonical_name(cluster) do
    case cluster do
      [] ->
        ""

      _ ->
        cluster
        |> Enum.min_by(fn e ->
          {-String.length(e.name || ""), e.id || ""}
        end)
        |> Map.get(:name, "")
    end
  end

  defp write_canonical(super_graph, canonical_id, cluster) do
    name = pick_canonical_name(cluster)
    head = List.first(cluster) || %{}
    primary_type = Map.get(head, :type) || "concept"
    subtype = Map.get(head, :subtype)
    normalized_subtype = Map.get(head, :normalized_subtype)

    avg_embedding = average_embeddings(Enum.map(cluster, & &1.embedding))
    max_tier = EdgeAggregation.max_trust_tier(Enum.map(cluster, & &1.trust_tier))
    last_evidence_at = DateTime.utc_now() |> DateTime.to_iso8601()

    source_count =
      cluster |> Enum.map(& &1.source_graph) |> Enum.uniq() |> length()

    props =
      %{
        id: canonical_id,
        name: name,
        primary_type: primary_type,
        subtype: subtype,
        normalized_subtype: normalized_subtype,
        embedding: avg_embedding,
        trust_tier: max_tier,
        importance_score: 0.0,
        source_count: source_count,
        last_evidence_at: last_evidence_at,
        built_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        migration_marker: Migration.canonical_version()
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    Magus.Graph.upsert_node(super_graph, "CanonicalEntity", props)
  end

  defp average_embeddings([]), do: []

  defp average_embeddings(embeddings) do
    embeddings_filtered = Enum.reject(embeddings, &(&1 == [] or is_nil(&1)))

    if embeddings_filtered == [] do
      []
    else
      n = length(embeddings_filtered)
      dim = embeddings_filtered |> List.first() |> length()

      if dim == 0 do
        []
      else
        Enum.map(0..(dim - 1), fn i ->
          sum =
            embeddings_filtered
            |> Enum.map(&Enum.at(&1, i, 0.0))
            |> Enum.sum()

          sum / n
        end)
      end
    end
  end

  defp write_source_pointer_and_appears_in(super_graph, canonical_id, instance, actor) do
    pointer_id =
      :crypto.hash(:sha256, "#{instance.source_graph}|#{instance.id}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    pointer_result =
      Magus.Graph.upsert_node(super_graph, "SourcePointer", %{
        id: pointer_id,
        graph_name: instance.source_graph,
        source_node_id: instance.id,
        source_refs: SourceRefs.encode(Map.get(instance, :source_refs, []))
      })

    # GraphWeight.weight_for/2 looks up user-scoped overrides keyed by
    # `actor.id` (must be a uuid), then falls back to the prefix-default
    # weight when no override matches. Passing the accessor's user lets
    # personal weight overrides apply if/when they exist; otherwise the
    # default fires.
    source_weight = GraphWeight.weight_for(instance.source_graph, actor)

    edge_result =
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
          graph_name: instance.source_graph,
          source_node_id: instance.id,
          mention_count: 1,
          latest_evidence_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          source_weight: source_weight
        }
      )

    empty_writes()
    |> tally(pointer_result)
    |> tally(edge_result)
  end

  # ---------------------------------------------------------------------------
  # Cross-graph RELATES_TO aggregation
  # ---------------------------------------------------------------------------

  defp aggregate_relates_to(super_graph, clusters, read_set) do
    entity_to_canonical =
      clusters
      |> Enum.flat_map(fn cluster ->
        canonical_id = canonical_id_for(super_graph, cluster)
        Enum.map(cluster, fn instance -> {instance.id, canonical_id} end)
      end)
      |> Map.new()

    edges =
      Enum.flat_map(read_set, fn graph_name ->
        case Magus.Graph.query(
               graph_name,
               """
               MATCH (a:Entity)-[r:RELATES_TO]->(b:Entity)
               RETURN a.id, b.id, r.predicate, r.confidence, r.trust_tier
               """,
               %{}
             ) do
          {:ok, %{rows: rows}} ->
            Enum.map(rows, fn [a_id, b_id, pred, conf, tier] ->
              %{
                source_graph: graph_name,
                from_canonical: Map.get(entity_to_canonical, a_id),
                to_canonical: Map.get(entity_to_canonical, b_id),
                predicate: pred,
                confidence: FalkorValues.parse_number(conf, 0.0),
                trust_tier: tier
              }
            end)

          _ ->
            []
        end
      end)
      |> Enum.reject(fn e -> is_nil(e.from_canonical) or is_nil(e.to_canonical) end)
      # iter5 Task 3.6: drop self-edges. A Layer 1 RELATES_TO whose
      # endpoints fuse into the same canonical (e.g. two aliases of the
      # same project clustering together) would otherwise materialize as
      # a canonical->itself loop, which is never useful for retrieval and
      # confuses downstream rankers.
      |> Enum.reject(fn e -> e.from_canonical == e.to_canonical end)

    aggregates =
      edges
      |> Enum.map(fn e ->
        %{
          from: e.from_canonical,
          to: e.to_canonical,
          predicate: e.predicate,
          confidence: e.confidence,
          trust_tier: e.trust_tier,
          source_graph: e.source_graph
        }
      end)
      |> EdgeAggregation.aggregate()

    writes =
      Enum.reduce(aggregates, empty_writes(), fn agg, w_acc ->
        edge_result =
          Magus.Graph.upsert_edge(
            super_graph,
            %{
              from_label: "CanonicalEntity",
              from_id: agg.from,
              to_label: "CanonicalEntity",
              to_id: agg.to
            },
            "RELATES_TO",
            %{
              predicate: agg.predicate,
              confidence: agg.confidence,
              trust_tier: agg.trust_tier,
              source_graphs: agg.source_graphs,
              extractor: @extractor_version,
              contested: agg.contested,
              predicate_breakdown: Jason.encode!(agg.predicate_breakdown),
              appearance_count: agg.appearance_count
            }
          )

        tally(w_acc, edge_result)
      end)

    %{edge_count: length(aggregates), writes: writes}
  end

  # ---------------------------------------------------------------------------
  # Importance scoring
  # ---------------------------------------------------------------------------

  defp compute_importance_scores(super_graph) do
    cypher = """
    MATCH (c:CanonicalEntity)
    OPTIONAL MATCH (c)-[a:APPEARS_IN]->(s:SourcePointer)
    RETURN c.id, c.source_count,
           collect({mention_count: a.mention_count, source_weight: a.source_weight}) AS appearances
    """

    case Magus.Graph.query(super_graph, cypher, %{}) do
      {:ok, %{rows: rows}} ->
        Enum.each(rows, fn [canonical_id, source_count, appearances] ->
          score = compute_score(source_count, appearances)

          _ =
            Magus.Graph.query(
              super_graph,
              "MATCH (c:CanonicalEntity {id: $id}) SET c.importance_score = $score",
              %{id: canonical_id, score: score}
            )
        end)

        :ok

      {:error, _} = err ->
        err
    end
  end

  # Raw popularity only: `source_count * sum(source_weight * log(1 + mention_count))`.
  # The trust-tier multiplier is applied once at query time in
  # `Magus.SuperBrain.Retrieval`. Baking it into the stored score would
  # cause double-application when the ranker re-multiplies by tier_mult.
  defp compute_score(source_count, appearances) when is_list(appearances) do
    source_count = FalkorValues.parse_number(source_count, 1.0) |> max(1.0)

    appearance_sum =
      Enum.reduce(appearances, 0.0, fn a, acc ->
        mention =
          FalkorValues.parse_number(
            Map.get(a, "mention_count") || Map.get(a, :mention_count),
            1.0
          )

        weight =
          FalkorValues.parse_number(
            Map.get(a, "source_weight") || Map.get(a, :source_weight),
            1.0
          )

        acc + weight * :math.log(1 + mention)
      end)

    source_count * appearance_sum
  end

  defp compute_score(_source_count, _appearances), do: 0.0

  # ---------------------------------------------------------------------------
  # Write-error accounting
  # ---------------------------------------------------------------------------

  defp empty_writes, do: %{total: 0, errors: 0}

  defp record_success(%{total: t, errors: e}), do: %{total: t + 1, errors: e}
  defp record_failure(%{total: t, errors: e}), do: %{total: t + 1, errors: e + 1}

  defp combine_writes(%{total: t1, errors: e1}, %{total: t2, errors: e2}) do
    %{total: t1 + t2, errors: e1 + e2}
  end

  # Classify a Magus.Graph upsert result and fold it into the counter.
  defp tally(acc, {:ok, _}), do: record_success(acc)

  defp tally(acc, {:error, reason}) do
    Logger.warning("BuildSuperFull: FalkorDB write error: #{inspect(reason)}")
    record_failure(acc)
  end

  defp tally(acc, _other), do: record_success(acc)

  # Gate the swap on write-error rate. A handful of transient errors are
  # tolerable; a systemic problem (bad index, malformed data) easily
  # blows past the threshold and is what this check catches. The build
  # fails without swapping so the live graph is preserved.
  defp check_write_errors(_staging_name, %{total: 0}), do: :ok

  defp check_write_errors(staging_name, %{total: total, errors: errors}) do
    rate = errors / total

    if rate > @write_error_threshold do
      Logger.error(
        "BuildSuperFull: write-error rate #{Float.round(rate * 100, 2)}% (#{errors}/#{total}) " <>
          "exceeds threshold; refusing to swap staging #{staging_name} into live"
      )

      {:error, {:too_many_write_errors, %{total: total, errors: errors, rate: rate}}}
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Swap staging -> live
  # ---------------------------------------------------------------------------

  # FalkorDB v4 exposes `GRAPH.COPY` but no atomic overwrite primitive.
  # The swap is therefore:
  #
  #   1. GRAPH.DELETE live (no-op if it does not exist)
  #   2. GRAPH.COPY staging live (errors if live still exists)
  #   3. GRAPH.DELETE staging (cleanup)
  #
  # Between (1) and the end of (2) queries against the live graph see
  # "empty" (or `:graph_unavailable` from the circuit breaker). This
  # window is bounded by FalkorDB's copy time for the staging graph
  # (typically a fraction of a second); the pre-iter5 design left the
  # graph empty for the whole build duration on a crash, which could be
  # minutes-to-hours until `SuperGraphMaintenance` reran.
  defp swap_into_live(staging_name, live_name) do
    with {:ok, _} <- drop_graph_for_swap(live_name),
         :ok <- copy_for_swap(staging_name, live_name),
         {:ok, _} <- drop_graph_for_swap(staging_name) do
      :ok
    else
      {:error, _} = err -> err
    end
  end

  # `GRAPH.DELETE` against a non-existent graph errors with
  # "Invalid graph operation on empty key" in FalkorDB. We treat that
  # as success: the post-condition we want is "this graph name does
  # not exist", which is already true. Any OTHER error is real and
  # surfaced.
  defp drop_graph_for_swap(name) do
    case Magus.Graph.drop(name) do
      {:ok, result} -> {:ok, result}
      :ok -> {:ok, :ok}
      {:error, %Redix.Error{message: msg}} -> handle_missing_graph(msg)
      {:error, msg} when is_binary(msg) -> handle_missing_graph(msg)
      {:error, _} = err -> err
    end
  end

  defp handle_missing_graph(msg) do
    if msg =~ "Invalid graph operation on empty key" or msg =~ "empty key" do
      {:ok, :missing}
    else
      {:error, msg}
    end
  end

  defp copy_for_swap(src, dst), do: copy_for_swap(src, dst, 0)

  defp copy_for_swap(src, dst, attempt) do
    case Magus.Graph.Connection.command(["GRAPH.COPY", prefixed(src), prefixed(dst)]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        if attempt < @copy_max_retries and transient_fork_failure?(reason) do
          backoff = @copy_retry_base_ms * 2 ** attempt

          Logger.warning(
            "BuildSuperFull: GRAPH.COPY #{src} -> #{dst} could not fork " <>
              "(attempt #{attempt + 1}/#{@copy_max_retries + 1}); retrying in #{backoff}ms"
          )

          Process.sleep(backoff)
          copy_for_swap(src, dst, attempt + 1)
        else
          Logger.error("BuildSuperFull: GRAPH.COPY #{src} -> #{dst} failed: #{inspect(reason)}")

          {:error, {:swap_failed, reason}}
        end
    end
  end

  # FalkorDB surfaces a failed `fork()` during `GRAPH.COPY` as a generic
  # Redix error whose message contains "could not fork". Such errors are
  # transient (memory pressure at the instant of the fork) and worth
  # retrying, unlike a structural copy error (e.g. the destination already
  # exists), which we want to surface immediately.
  defp transient_fork_failure?(%Redix.Error{message: msg}) when is_binary(msg) do
    String.contains?(msg, "could not fork")
  end

  defp transient_fork_failure?(_), do: false

  defp prefixed(graph_name) do
    prefix =
      Application.fetch_env!(:magus, Magus.Graph)
      |> Keyword.get(:graph_name_prefix, "")

    prefix <> graph_name
  end

  # ---------------------------------------------------------------------------
  # Status transitions
  # ---------------------------------------------------------------------------

  defp mark_built(super_row, read_set, canonical_count, edge_count, started_at) do
    snapshot =
      Enum.map(read_set, fn graph_name ->
        %{
          "graph_name" => graph_name,
          "snapshot_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      end)

    duration_ms = System.monotonic_time(:millisecond) - started_at

    Ash.update(
      super_row,
      %{
        read_set_snapshot: snapshot,
        canonical_entity_count: canonical_count,
        canonical_edge_count: edge_count,
        last_build_duration_ms: duration_ms
      },
      action: :mark_built,
      authorize?: false
    )
  end

  defp mark_failed_safe(accessor, reason) do
    case SuperGraph
         |> filter_by_accessor(accessor)
         |> Ash.read_one(authorize?: false) do
      {:ok, %SuperGraph{} = row} ->
        _ =
          Ash.update(row, %{last_error: inspect(reason)},
            action: :mark_failed,
            authorize?: false
          )

        :ok

      _ ->
        :ok
    end
  end
end
