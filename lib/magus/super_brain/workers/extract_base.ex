defmodule Magus.SuperBrain.Workers.ExtractBase do
  @moduledoc """
  Shared pipeline for Super Brain extraction workers.

  Each per-resource worker implements `load/1` to turn its Oban job args
  into a canonical episode input. The base module owns the rest of the
  pipeline:

      load -> budget -> fingerprint gate -> extract (LLM, no transaction)
        -> [transaction: re-gate -> claim episode -> mark_processing ->
            record_budget + usage -> write_to_graph -> mark_extracted]

  Outcomes (return values from `perform/1`):

    * `:ok` on success or when the fingerprint matches an already-extracted
      Episode (no-op).
    * `{:cancel, :budget_exceeded}` when the user's daily ceiling is hit.
    * `{:error, reason}` on extraction or graph failures. The worker also
      marks the Episode `:failed` with `last_error` for observability.
      Oban retries up to `max_attempts` based on this return.

  Usage tracking: every successful LLM call writes a
  `Magus.Usage.MessageUsage` row with `usage_type: :super_brain_extraction`
  via `Magus.SuperBrain.Usage`. The fast-path daily killswitch
  (`ExtractionBudget`) is still updated with the per-call `cost_cents`
  (derived from `total_cost`).

  Iron Laws:

    * Episode lookup in failure handling uses `Ash.Query.filter` with `^`
      pinning - no user-controlled string interpolation reaches the DB.
    * Graph entries are scoped by `source_id` (the Episode id) so manually
      curated entities and other episodes' entries survive re-extraction.
    * Wall-clock guard before the LLM call prevents runaway jobs.
    * `Atom.to_string/1` is only called on atoms produced by the sanitiser
      (known canonical set) - no atom-exhaustion DoS.

  ## Concurrency

  The slow LLM call runs OUTSIDE any Postgres transaction, so the pipeline
  never holds a pooled DB connection across it. Only the final persistence
  step (re-gate, claim episode, usage, graph writes, mark extracted) runs
  inside a short `Repo.transaction`.

  There is no cross-resource advisory lock. Three cheaper guards keep
  concurrent extractions of the same `(resource_type, resource_id)` correct
  and (almost always) non-redundant:

    * Oban's enqueue-time `unique: [period: 60, fields: [:args]]` coalesces
      duplicate triggers, so two jobs for the same resource rarely run at
      once in the first place.
    * The fingerprint gate is re-checked inside the persistence transaction
      (after the LLM call). If another worker extracted the same content
      while this one was calling the LLM, this worker exits via
      `:skip_unchanged` and discards its result.
    * A partial unique index (`super_brain_episodes_partial_unique`) lets at
      most one `:extracted` row exist per resource. In the rare event two
      workers reach `mark_extracted` simultaneously, the index rejects the
      loser; its job errors and Oban retries, then skips via the gate.

  The trade-off: in that rare race both workers may spend a single LLM
  extraction call, a cheap cost on an infrequent event, far cheaper than
  holding a Repo connection across a multi-minute HTTP call (connection-pool
  starvation, checkout timeouts).
  """

  alias Magus.Repo

  alias Magus.SuperBrain.{
    EmbeddingConfig,
    Episode,
    Extraction,
    ExtractionBudget,
    FalkorValues,
    Migration,
    Ontology,
    Usage
  }

  alias Magus.SuperBrain.Ontology.SubtypeNormalizer
  alias Magus.SuperBrain.Telemetry, as: SBTelemetry

  require Ash.Query
  require Logger

  @wall_clock_budget_ms 120_000

  # Inline canonicalize (iter3 Task 7): after entities are upserted to the
  # Layer 1 graph, run a KNN search to collapse near-duplicates of the same
  # `(type, normalized_subtype)` into a single node. Edges are re-pointed
  # from loser to winner; an audit row is written to
  # `super_brain_canonicalization_events`.
  @canonicalize_similarity_threshold 0.95
  @canonicalize_knn_k 5

  # Curated (user-instruction) nodes must never be merged by inline
  # canonicalize. The pin and link ingest workers stamp their
  # extractor_version with one of these prefixes; the guard excludes both
  # endpoints of any merge involving one.
  @curated_extractor_prefixes ["brain_pin_ingest", "brain_links_ingest"]

  @doc false
  def curated_extractor_prefixes, do: @curated_extractor_prefixes

  # Version stamp written to the audit table so retrospective analysis can
  # tell which version of the canonicalize logic produced a merge event.
  @inline_canonicalize_version "inline_canonicalize@2026-05-25"

  @type load_result :: %{
          required(:user_id) => String.t(),
          required(:raw_text) => String.t(),
          required(:graph_name) => String.t(),
          required(:resource_type) => atom(),
          required(:resource_id) => String.t(),
          optional(:source_weight) => float(),
          optional(:extra_node_props) => map(),
          optional(:ontology_source) => atom()
        }

  @callback load(args :: map()) :: {:ok, load_result()} | {:error, term()}
  @callback extractor_version() :: String.t()

  defmacro __using__(opts) do
    queue = Keyword.fetch!(opts, :queue)

    quote do
      use Oban.Worker,
        queue: unquote(queue),
        max_attempts: 5,
        unique: [period: 60, fields: [:args]]

      @behaviour Magus.SuperBrain.Workers.ExtractBase

      @impl Oban.Worker
      def perform(%Oban.Job{args: args}) do
        Magus.SuperBrain.Workers.ExtractBase.run_pipeline(__MODULE__, args)
      end
    end
  end

  @doc false
  def run_pipeline(worker_module, args) do
    if Magus.SuperBrain.enabled?() do
      run_pipeline_enabled(worker_module, args)
    else
      {:cancel, :super_brain_disabled}
    end
  end

  defp run_pipeline_enabled(worker_module, args) do
    started_at = System.monotonic_time(:millisecond)

    case worker_module.load(args) do
      {:ok, input} ->
        result = traced_pipeline(worker_module, input, started_at, args)

        # Best-effort fan-out (iter3 Task 11): after a successful extraction,
        # enqueue `BuildSuperIncremental` for every accessor whose read-set
        # includes the source graph. Runs after the persistence transaction so
        # a failed enqueue cannot roll back the extraction itself.
        # `:skip_unchanged` is collapsed to `:ok` by the persistence unwrap, so
        # in that case there is nothing fresh to fan out for.
        if result == :ok do
          enqueue_build_super_fan_out(input)
        end

        result

      {:error, reason} = err ->
        # Load failed: no Episode row exists yet (claim_episode runs after
        # load), so mark_episode_failed naturally no-ops. We still call it
        # for symmetry and to support any per-worker overrides.
        mark_episode_failed(args, reason, nil)
        err
    end
  end

  # Fan-out enqueue: for each accessor that can read `input.graph_name`,
  # enqueue a `BuildSuperIncremental` job. `Oban.insert/1` (not `!`) is used
  # deliberately - a failed enqueue is logged but never propagates back to
  # the extraction. The `BuildSuperIncremental` worker's own
  # `unique: [period: 30, fields: [:args]]` coalesces extraction bursts so a
  # flurry of writes to the same graph by the same user only triggers ~one
  # rebuild.
  defp enqueue_build_super_fan_out(input) do
    accessors = Magus.SuperBrain.AccessibleGraphs.accessors_of(input.graph_name)

    Enum.each(accessors, fn accessor ->
      args = %{
        "accessor_type" => Atom.to_string(accessor.type),
        "user_id" => accessor.user_id,
        "workspace_id" => accessor.workspace_id
      }

      case args
           |> Magus.SuperBrain.Workers.BuildSuperIncremental.new()
           |> Oban.insert() do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Super Brain fan-out enqueue failed for #{input.graph_name} -> #{inspect(accessor)}: #{inspect(reason)}"
          )

          :ok
      end
    end)

    :ok
  rescue
    # Narrow the rescue: only swallow the predictable misuses (missing
    # helper module, mistyped key, bad argument shape). Any other exception
    # (e.g. a DBConnection.ConnectionError mid-enqueue or an
    # ArithmeticError in someone else's code) should propagate so we don't
    # silently turn a correctness bug into a warning log.
    e in [UndefinedFunctionError, KeyError, ArgumentError] ->
      Logger.warning("Super Brain fan-out enqueue raised for #{input.graph_name}: #{inspect(e)}")

      :ok
  end

  # Telemetry + log-metadata wrapper around the three-phase pipeline. The LLM
  # call (phase 2) runs OUTSIDE any Postgres transaction; only persistence
  # (phase 3) opens a short `Repo.transaction`. See the "Concurrency" section
  # of the moduledoc for why there is no advisory lock.
  defp traced_pipeline(worker_module, input, started_at, args) do
    # Stamp every downstream warning/error log with the identity of the
    # extraction this process is running. Without these tags, the
    # `Logger.warning` calls inside embedder helpers, canonicalize, etc.
    # are anonymous and impossible to correlate with a specific user's
    # extraction in production. Logger.metadata is process-scoped and
    # automatically reset when the Oban worker process exits.
    Logger.metadata(
      super_brain_user_id: input.user_id,
      super_brain_graph: input.graph_name,
      super_brain_resource_id: input.resource_id,
      super_brain_resource_type: input.resource_type
    )

    metadata = %{
      worker: worker_module,
      user_id: input.user_id,
      graph_name: input.graph_name,
      resource_type: input.resource_type,
      resource_id: input.resource_id
    }

    :telemetry.span([:super_brain, :extract], metadata, fn ->
      result = gate_extract_persist(worker_module, input, started_at, args)
      {result, Map.merge(metadata, span_outcome(result))}
    end)
  end

  # `:telemetry.span/3` emits `:stop` on ANY normal return, so a `{:error,
  # reason}` extraction (e.g. `:invalid_json`) would otherwise be logged as
  # "ok" by `TelemetryHandler`. Tag the real outcome in the stop metadata so
  # the handler logs failures as warnings instead of masking them as success.
  defp span_outcome(:ok), do: %{outcome: :ok}
  defp span_outcome(:skip_unchanged), do: %{outcome: :skipped}
  defp span_outcome({:error, reason}), do: %{outcome: :error, error_reason: inspect(reason)}
  defp span_outcome({:cancel, reason}), do: %{outcome: :cancelled, error_reason: inspect(reason)}
  defp span_outcome(_), do: %{outcome: :ok}

  # Phase 1 (budget + fingerprint gate, reads only) and phase 2 (the LLM
  # call), both OUTSIDE any transaction so no pooled DB connection is held
  # across the slow HTTP call. On success, hands off to phase 3
  # (`persist_extraction/5`).
  defp gate_extract_persist(worker_module, input, started_at, args) do
    new_fingerprint = :crypto.hash(:sha256, input.raw_text || "")

    with :ok <- check_budget(input.user_id),
         :continue <-
           gate_on_fingerprint(input.resource_type, input.resource_id, new_fingerprint),
         {:ok, extraction} <- run_extraction(input, started_at) do
      persist_extraction(worker_module, input, extraction, new_fingerprint, args)
    else
      :skip_unchanged -> :ok
      {:error, :budget_exceeded} -> {:cancel, :budget_exceeded}
      {:error, reason} -> {:error, reason}
    end
  end

  # Phase 3: persist the extraction in a short transaction (no advisory lock).
  # The fingerprint gate is re-checked first: if another worker extracted the
  # same content while this worker was calling the LLM, we discard our result
  # via `:skip_unchanged` instead of churning the graph. `claim_episode`'s
  # supersede now runs only after a successful LLM call, so a failed LLM call
  # leaves the prior extraction intact.
  defp persist_extraction(worker_module, input, extraction, new_fingerprint, args) do
    Repo.transaction(fn ->
      with :continue <-
             gate_on_fingerprint(input.resource_type, input.resource_id, new_fingerprint),
           :ok <- ensure_graph_indexes(input.graph_name),
           {:ok, episode} <- claim_episode(input, worker_module),
           {:ok, episode} <- mark_processing(episode),
           :ok <- record_budget_and_usage(input.user_id, extraction),
           :ok <- write_to_graph(input, episode, extraction, worker_module),
           {:ok, _} <- mark_extracted(episode, extraction) do
        :ok
      else
        :skip_unchanged -> :skip_unchanged
        {:error, reason} -> {:error, reason}
      end
    end)
    |> unwrap_persist_result(args, input.resource_type)
  end

  # The transaction returns `{:ok, inner}` when the function body completes
  # (the body returns plain values, not ok-tuples, so failures surface as
  # `{:ok, {:error, _}}` here rather than aborting the transaction). We
  # translate those back into the worker's return shape and, on failure, mark
  # the Episode `:failed` OUTSIDE the transaction so the failure log survives.
  defp unwrap_persist_result({:ok, :ok}, _args, _resource_type), do: :ok
  defp unwrap_persist_result({:ok, :skip_unchanged}, _args, _resource_type), do: :ok

  defp unwrap_persist_result({:ok, {:error, reason}}, args, resource_type) do
    mark_episode_failed(args, reason, resource_type)
    {:error, reason}
  end

  defp unwrap_persist_result({:error, reason}, args, resource_type) do
    mark_episode_failed(args, reason, resource_type)
    {:error, reason}
  end

  # Persistence (`persist_extraction/5`) runs inside a manual
  # `Repo.transaction/1` so the Episode swap + graph writes commit atomically.
  # Ash mutations executed inside that transaction (the Episode lifecycle
  # transitions and the `MessageUsage` write) produce notifications Ash cannot
  # dispatch while the transaction is open: `Ash.Notifier.notify/1` sees the
  # data layer still in a transaction, returns them as "unsent", and logs a
  # "Missed N notifications in action ..." warning for each one.
  #
  # Episode and MessageUsage declare no notifiers (no `pub_sub`; they are
  # internal bookkeeping), so the notifications carry no subscribers. We pass
  # `return_notifications?: true` and discard them, which silences the warning
  # without changing behaviour. If either resource ever gains a notifier, this
  # is the spot to flush them via `Ash.Notifier.notify/1` after commit instead.
  defp drop_notifications({:ok, record, _notifications}), do: {:ok, record}
  defp drop_notifications(other), do: other

  # ---------------------------------------------------------------------------
  # Budget and fingerprint gating
  # ---------------------------------------------------------------------------

  defp check_budget(user_id) do
    today = Date.utc_today()

    if ExtractionBudget.would_exceed_ceiling?(user_id, today) do
      SBTelemetry.budget_exhausted(user_id, today)
      {:error, :budget_exceeded}
    else
      :ok
    end
  end

  # With append-only Episodes (D7), a `(resource_type, resource_id)` tuple
  # may have many `:superseded` rows plus at most one `:extracted` row.
  # Filter to `status == :extracted` so `read_one` only sees the current
  # row and never returns `{:error, :multiple_results}`.
  defp gate_on_fingerprint(resource_type, resource_id, new_fingerprint) do
    case Episode
         |> Ash.Query.filter(
           resource_type == ^resource_type and
             resource_id == ^resource_id and
             status == :extracted
         )
         |> Ash.read_one(authorize?: false) do
      {:ok, %Episode{content_fingerprint: ^new_fingerprint}} ->
        :skip_unchanged

      _ ->
        :continue
    end
  end

  # ---------------------------------------------------------------------------
  # Graph index bootstrap
  # ---------------------------------------------------------------------------

  # Ensure the FalkorDB vector index for `Entity.embedding` exists for this
  # graph before we write any embedded entities. This used to live only in
  # tests, which meant production graphs never had the index and
  # `Magus.Graph.Vector.knn_search/5` would silently return zero hits.
  #
  # The call is best-effort: if it fails we still proceed with the
  # extraction pipeline. The downstream `upsert_node` calls will either
  # succeed without the index (and a later run will heal the index) or
  # fail loudly with a surfaced error.
  defp ensure_graph_indexes(graph_name) do
    _ =
      Magus.Graph.Vector.ensure_index(graph_name, "Entity", "embedding",
        dim: EmbeddingConfig.dim(),
        similarity: :cosine
      )

    :ok
  end

  # ---------------------------------------------------------------------------
  # Episode lifecycle
  # ---------------------------------------------------------------------------

  # Append-only Episodes (closes D7): instead of upserting the existing row
  # in place, supersede any prior `:extracted` Episode for this resource
  # and create a fresh row. This runs inside the persistence transaction
  # AFTER a successful LLM call, and re-checks the fingerprint gate first, so
  # the common concurrent case is already filtered out. The partial unique
  # index (`super_brain_episodes_partial_unique`, one `:extracted` per
  # resource) is the final backstop: in the rare event two workers reach
  # `mark_extracted` simultaneously, the index rejects the loser, whose job
  # then errors and is retried by Oban (skipping via the gate). See the
  # moduledoc "Concurrency" section.
  #
  # Prior graph nodes (Episode + tagged Entities) are removed as part of
  # superseding so the FalkorDB view stays in lock-step with the current
  # `:extracted` row. Postgres preserves the full Episode history for
  # replay; the graph only ever holds the latest extraction's nodes per
  # source.
  defp claim_episode(input, worker_module) do
    extractor_version = worker_module.extractor_version()

    _ =
      supersede_prior(
        input.resource_type,
        input.resource_id,
        input.graph_name,
        extractor_version
      )

    Episode
    |> Ash.Changeset.for_create(
      :create,
      %{
        resource_type: input.resource_type,
        resource_id: input.resource_id,
        graph_name: input.graph_name,
        raw_text: input.raw_text || "",
        source_user_id: input.user_id,
        source_weight: Map.get(input, :source_weight, 1.0),
        extractor_version: extractor_version
      },
      actor: %{id: input.user_id}
    )
    |> Ash.create(actor: %{id: input.user_id}, return_notifications?: true)
    |> drop_notifications()
  end

  # Supersede every non-terminal prior row for the same resource. Previously
  # this only matched `:extracted`, which let `:failed`, `:processing`, and
  # `:pending` zombies accumulate over time. Combined with `find_episode/1`
  # not filtering by `resource_type`, two stale rows for the same resource_id
  # but different resource_types would trip `read_one`'s multiple-results
  # guard and silently no-op `mark_episode_failed`. We now drive every prior
  # non-`:superseded` row to `:superseded` so the next claim has a clean
  # slate.
  defp supersede_prior(resource_type, resource_id, graph_name, extractor_version) do
    case Episode
         |> Ash.Query.filter(
           resource_type == ^resource_type and
             resource_id == ^resource_id and
             status in [:pending, :processing, :extracted, :failed]
         )
         |> Ash.read(authorize?: false) do
      {:ok, priors} when is_list(priors) and priors != [] ->
        Enum.each(priors, fn prior ->
          # Remove the prior Episode's graph footprint BEFORE flipping its
          # status so a partial failure leaves the row in its prior state
          # (still owning the graph nodes). The graph delete is not
          # transactional but `delete_prior_extraction` is idempotent so
          # re-running is safe.
          _ = delete_prior_extraction(graph_name, extractor_version, prior.id)

          _ =
            Ash.update(prior, %{},
              action: :supersede,
              actor: %{id: prior.source_user_id},
              return_notifications?: true
            )
            |> drop_notifications()
        end)

        :ok

      _ ->
        :ok
    end
  end

  defp mark_processing(%Episode{} = episode) do
    Ash.update(episode, %{},
      action: :mark_processing,
      actor: %{id: episode.source_user_id},
      return_notifications?: true
    )
    |> drop_notifications()
  end

  defp mark_extracted(%Episode{} = episode, extraction) do
    Ash.update(episode, %{extraction_model: extraction_model_from(extraction)},
      action: :mark_extracted,
      actor: %{id: episode.source_user_id},
      return_notifications?: true
    )
    |> drop_notifications()
  end

  defp extraction_model_from(%{usage: %Usage{model_name: name}}), do: name
  defp extraction_model_from(_), do: nil

  defp mark_episode_failed(args, reason, resource_type) do
    with %{} = args <- args,
         {:ok, resource_id} <- fetch_resource_id(args),
         {:ok, %Episode{} = e} <- find_episode(resource_id, resource_type) do
      _ =
        Ash.update(e, %{last_error: inspect(reason)},
          action: :mark_failed,
          actor: %{id: e.source_user_id}
        )

      :ok
    else
      _ -> :ok
    end
  end

  defp fetch_resource_id(%{"resource_id" => rid}) when is_binary(rid), do: {:ok, rid}
  defp fetch_resource_id(%{"page_id" => rid}) when is_binary(rid), do: {:ok, rid}
  defp fetch_resource_id(_), do: :error

  # With append-only Episodes (D7), `(resource_type, resource_id)` may have
  # many `:superseded` rows. Filter to in-flight statuses so we find the
  # row this job actually created and never trip `read_one`'s multiple-
  # results guard. When `resource_type` is known (the in-pipeline failure
  # paths), additionally filter by it: previously two stale rows sharing a
  # `resource_id` but differing on `resource_type` would trip the multi
  # guard and silently no-op the failure update.
  defp find_episode(resource_id, nil) do
    Episode
    |> Ash.Query.filter(resource_id == ^resource_id and status in [:pending, :processing])
    |> Ash.read_one(authorize?: false)
  end

  defp find_episode(resource_id, resource_type) when is_atom(resource_type) do
    Episode
    |> Ash.Query.filter(
      resource_id == ^resource_id and
        resource_type == ^resource_type and
        status in [:pending, :processing]
    )
    |> Ash.read_one(authorize?: false)
  end

  # ---------------------------------------------------------------------------
  # Extraction with wall-clock guard
  # ---------------------------------------------------------------------------

  defp run_extraction(input, started_at) do
    cond do
      blank?(input.raw_text) ->
        # Nothing to extract. Return an empty result (no LLM call) so the
        # resource still earns an :extracted Episode and the backfill stops
        # re-picking it every tick. Omitting `:usage` routes to the no-Usage
        # `record_budget_and_usage/2` clause (budget bump, no MessageUsage),
        # and the empty entity/edge lists make `write_to_graph/4` skip every
        # embedder call (see `embed_text("")` / `embed_entities([])`).
        {:ok, %{entities: [], edges: [], user_id: input.user_id}}

      System.monotonic_time(:millisecond) - started_at > @wall_clock_budget_ms ->
        {:error, :wall_clock_exceeded}

      true ->
        Extraction.extract(input.raw_text, user_id: input.user_id)
    end
  end

  # Whitespace-only or nil content has nothing to extract. We treat it as a
  # successful empty extraction (above) rather than failing on `Episode.create`
  # (raw_text is `allow_nil? false`) or burning an LLM call on empty input.
  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank?(_), do: false

  # Increments the per-day killswitch budget and (when a Usage struct is
  # present on the extraction result) writes a `MessageUsage` row attributed
  # to the user. Failures to write `MessageUsage` are logged but never abort
  # the pipeline - the graph write is the load-bearing side effect.
  defp record_budget_and_usage(user_id, %{usage: %Usage{} = usage}) do
    cents = usage_to_cents(usage)

    :ok =
      ExtractionBudget.atomic_increment(user_id, Date.utc_today(),
        calls: 1,
        cost_cents: cents
      )

    case Usage.write_message_usage(usage, user_id, :super_brain_extraction,
           return_notifications?: true
         ) do
      {:ok, _row, _notifications} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to write MessageUsage for super_brain_extraction: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp record_budget_and_usage(user_id, _extraction) do
    ExtractionBudget.atomic_increment(user_id, Date.utc_today(),
      calls: 1,
      cost_cents: 0
    )
  end

  defp usage_to_cents(%Usage{total_cost: %Decimal{} = cost}) do
    cost
    |> Decimal.mult(100)
    |> Decimal.round(0)
    |> Decimal.to_integer()
  end

  defp usage_to_cents(_), do: 0

  # ---------------------------------------------------------------------------
  # Graph writes (source-scoped re-extraction)
  # ---------------------------------------------------------------------------

  # Cap raw_text on the Episode node so a 10 MB file doesn't bloat FalkorDB.
  # The full text remains in the Episode Ash resource for re-extraction; the
  # graph copy is for context-window-sized retrieval previews.
  @episode_raw_text_max 4_000

  # Spec schema (closes D1):
  #
  #   (:Episode {id, resource_type, resource_id, raw_text, embedding,
  #              occurred_at, source_user_id, source_weight, extractor,
  #              source_id})
  #     -[:HAS_ENTITY {confidence, extracted_at, extractor, source_id}]->
  #   (:Entity {id, name, type, subtype, embedding, confidence, trust_tier,
  #            extractor, source_id, <extra props from worker>})
  #     -[:RELATES_TO {predicate, confidence, trust_tier, extractor,
  #                    source_id}]->
  #   (:Entity ...)
  #
  # Embeddings: the Episode's raw_text plus each Entity name is embedded so
  # retrieval-time `knn_search` against the Entity vector index actually
  # returns hits. We batch entity names via the configured
  # `:super_brain_extraction_embedder` (production:
  # `Magus.Embeddings.OpenAIBatchEmbedder`; tests: a Mox mock returning
  # zero-vectors). Failures degrade gracefully: nodes still write without
  # the `embedding` property so the rest of the pipeline never blocks on
  # embedder availability.
  defp write_to_graph(input, %Episode{id: episode_id}, extraction, worker_module) do
    graph_name = input.graph_name
    extractor_version = worker_module.extractor_version()
    extra = Map.get(input, :extra_node_props, %{})
    # Iter4 Task 4: per-resource workers can elevate the trust-tier source
    # (e.g. `:user_curated` for important callouts, `:memory_explicit` for
    # explicit memory kinds). Default `:llm_extract` keeps existing behavior.
    ontology_source = Map.get(input, :ontology_source, :llm_extract)

    # Iter4 Task 9: warn when high-ambiguity entity types are emitted
    # without a subtype. Subtype-less :person / :organization / :project
    # entities collapse into a single canonical per `(name, type)` bucket
    # in the super graph, which is the worst-case failure mode for entity
    # disambiguation (e.g. the actual user "Daniel" and an unlabeled
    # fictional "Daniel" sharing one canonical). Surfacing these via logs
    # lets us iterate on the extraction prompt or per-resource subtype
    # hints as omissions show up in real runs.
    warn_on_ambiguous_subtypes(extraction.entities, input, worker_module)

    # NB: `delete_prior_extraction(graph_name, extractor_version, episode_id)`
    # used to run here. It's a no-op in the new-episode write path because
    # `episode_id` is the brand-new Ash UUID and no FalkorDB nodes carry it
    # as `source_id` yet. The supersede-cleanup call in `supersede_prior/4`
    # passes `prior.id` and remains load-bearing.
    with {:ok, episode_embedding} <- embed_text(input.raw_text),
         {:ok, entities_with_embeddings} <- embed_entities(extraction.entities) do
      write_episode_node(
        graph_name,
        episode_id,
        input,
        episode_embedding,
        extractor_version
      )

      # Build a name -> type lookup so RELATES_TO endpoint stable_ids can
      # be recomputed with the same `(graph_name, type, downcase(name))`
      # shape used for the Entity nodes (Task 3.4). The sanitizer already
      # filters edges to those whose subject_name/object_name are present
      # in the entities list, so every edge endpoint is guaranteed to find
      # a hit here. Ambiguous names (same name appearing with two
      # different types in the same extraction) emit a telemetry counter
      # and fall back to the first occurrence; this keeps existing
      # behavior working while making the rare case observable.
      entity_type_lookup =
        build_entity_type_lookup(entities_with_embeddings, input.graph_name)

      # Write entity nodes first, then run inline canonicalize against the
      # freshly-upserted nodes, then write the :HAS_ENTITY edges. The
      # ordering is load-bearing: canonicalize re-points edges from loser
      # to winner, so doing it before edge writes means the new HAS_ENTITY
      # edge from this episode points at the winner directly (no fix-up
      # needed) and reduces the number of edges that have to be migrated.

      entity_write_results =
        Enum.map(entities_with_embeddings, fn {entity, embedding} ->
          case write_entity_node(
                 graph_name,
                 entity,
                 embedding,
                 extra,
                 episode_id,
                 extractor_version,
                 ontology_source
               ) do
            {:ok, _} -> {:ok, entity_descriptor(graph_name, entity, embedding, extractor_version)}
            {:error, _} = err -> err
          end
        end)

      upserted_entities =
        for {:ok, descriptor} <- entity_write_results, do: descriptor

      canonicalize_inline(graph_name, upserted_entities)

      has_entity_results =
        Enum.map(entities_with_embeddings, fn {entity, _embedding} ->
          case write_has_entity_edge(graph_name, episode_id, entity, extractor_version) do
            {:ok, _} -> :ok
            {:error, _} = err -> err
          end
        end)

      entity_results = entity_write_results ++ has_entity_results

      edge_results =
        Enum.map(extraction.edges, fn edge ->
          trust = Ontology.compute_trust_tier(edge.confidence, source: ontology_source)

          subject_type = Map.get(entity_type_lookup, edge.subject_name)
          object_type = Map.get(entity_type_lookup, edge.object_name)

          Magus.Graph.upsert_edge(
            graph_name,
            %{
              from_label: "Entity",
              from_id: stable_id(graph_name, edge.subject_name, subject_type),
              to_label: "Entity",
              to_id: stable_id(graph_name, edge.object_name, object_type)
            },
            "RELATES_TO",
            %{
              predicate: predicate_to_string(edge.predicate),
              confidence: edge.confidence,
              trust_tier: Atom.to_string(trust),
              extractor: extractor_version,
              source_id: episode_id
            }
          )
        end)

      case Enum.find(entity_results ++ edge_results, &match?({:error, _}, &1)) do
        nil -> :ok
        {:error, _} = err -> err
      end
    else
      {:error, _} = err -> err
    end
  end

  # Iter4 Task 9: log a warning when a high-ambiguity entity type is
  # emitted without a subtype. The three types here are the ones where a
  # missing subtype tends to fuse semantically-different referents under
  # one canonical (e.g. the actual user vs an unlabeled fictional
  # character of the same name). The log gives us a signal to iterate on
  # the extraction prompt or add per-resource subtype hints; it never
  # aborts or alters extraction.
  @ambiguous_subtype_types ~w(person organization project)a

  defp warn_on_ambiguous_subtypes(entities, input, worker_module)
       when is_list(entities) do
    resource_label =
      "#{worker_module} resource=#{inspect(Map.get(input, :resource_type))}:#{Map.get(input, :resource_id)}"

    Enum.each(entities, fn entity ->
      type = Map.get(entity, :type)
      subtype = Map.get(entity, :subtype)
      name = Map.get(entity, :name)

      if type in @ambiguous_subtype_types and is_nil_or_blank(subtype) do
        Logger.warning(
          "super_brain: ambiguous subtype omitted for #{type} #{inspect(name)} " <>
            "(#{resource_label})"
        )
      end
    end)

    :ok
  end

  defp warn_on_ambiguous_subtypes(_, _, _), do: :ok

  defp is_nil_or_blank(nil), do: true
  defp is_nil_or_blank(""), do: true
  defp is_nil_or_blank(s) when is_binary(s), do: String.trim(s) == ""
  defp is_nil_or_blank(_), do: false

  # Source-scoped re-extraction (iter5 Task 3.6): delete prior :Episode and
  # only ORPHANED :Entity nodes tagged with the prior episode's source_id.
  #
  # The Episode node is always wiped (its HAS_ENTITY edges go via DETACH).
  # An Entity is wiped only when no other Episode in the graph still has a
  # HAS_ENTITY edge to it. This matters because entities are MERGEd by
  # stable_id `(graph_name, type, downcase(name))`, so a name like "Daniel"
  # shared across two pages lives in ONE FalkorDB node and its source_id
  # property is overwritten by the most recent writer. Without the orphan
  # check, re-extracting one page would delete the node that another,
  # still-extracted page also depends on.
  #
  # FalkorDB / OpenCypher does not support DETACH DELETE inside a WITH
  # branch with a conditional, so we issue two separate queries: the
  # Episode delete is unconditional, then a second pass removes any Entity
  # that was orphaned by it. The two-step is also easier to read than a
  # single ALL(...)-flavored CASE.
  defp delete_prior_extraction(graph_name, extractor_version, episode_id) do
    with {:ok, _} <-
           Magus.Graph.query(
             graph_name,
             """
             MATCH (ep:Episode)
             WHERE ep.extractor = $v AND ep.source_id = $sid
             DETACH DELETE ep
             """,
             %{v: extractor_version, sid: episode_id}
           ),
         {:ok, _} <-
           Magus.Graph.query(
             graph_name,
             """
             MATCH (e:Entity)
             WHERE e.extractor = $v AND e.source_id = $sid
               AND NOT EXISTS((:Episode)-[:HAS_ENTITY]->(e))
             DETACH DELETE e
             """,
             %{v: extractor_version, sid: episode_id}
           ) do
      :ok
    else
      {:error, _} = err -> err
    end
  end

  defp write_episode_node(graph_name, episode_id, input, embedding, extractor_version) do
    props =
      %{
        id: episode_id,
        resource_type: Atom.to_string(input.resource_type),
        resource_id: input.resource_id,
        raw_text: clip_text(input.raw_text, @episode_raw_text_max),
        source_user_id: input.user_id,
        source_weight: Map.get(input, :source_weight, 1.0),
        extractor: extractor_version,
        occurred_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        source_id: episode_id
      }
      |> maybe_put_embedding(embedding)

    Magus.Graph.upsert_node(graph_name, "Episode", props)
  end

  defp write_entity_node(
         graph_name,
         entity,
         embedding,
         extra,
         episode_id,
         extractor_version,
         ontology_source
       ) do
    trust = Ontology.compute_trust_tier(entity.confidence, source: ontology_source)
    normalized_subtype = SubtypeNormalizer.normalize(entity.subtype)

    props =
      Map.merge(extra, %{
        id: stable_id(graph_name, entity.name, entity.type),
        name: entity.name,
        type: Atom.to_string(entity.type),
        subtype: entity.subtype,
        normalized_subtype: normalized_subtype,
        confidence: entity.confidence,
        trust_tier: Atom.to_string(trust),
        extractor: extractor_version,
        source_id: episode_id,
        migration_marker: Migration.entity_version()
      })
      |> maybe_put_embedding(embedding)

    Magus.Graph.upsert_node(graph_name, "Entity", props)
  end

  # ---------------------------------------------------------------------------
  # Inline canonicalize (iter3 Task 7)
  #
  # After each batch of entities is upserted, run KNN over the entity vector
  # index to find near-duplicates of the same `(type, normalized_subtype)`
  # above the cosine threshold and merge them. Curated entities (pin- and
  # link-ingested) are user-declared and must NEVER be merged. The
  # `IngestBrainPin` / `IngestBrainLinks` workers stamp every node they write
  # with a curated extractor prefix (`brain_pin_ingest` / `brain_links_ingest`)
  # in its extractor version, so such entities are excluded from both ends of
  # the merge and preserved verbatim.
  #
  # Each merge re-points incident edges from loser to winner via MERGE
  # (idempotent, parallel-edge safe), DETACH DELETEs the loser, and writes
  # an audit row to `super_brain_canonicalization_events`. Failures are
  # logged but never abort the extraction pipeline - the worst case is that
  # a duplicate survives until the next extraction re-tries the merge.
  # ---------------------------------------------------------------------------

  defp canonicalize_inline(_graph_name, []), do: :ok

  defp canonicalize_inline(graph_name, new_entities) when is_list(new_entities) do
    Enum.each(new_entities, fn new_entity ->
      canonicalize_one(graph_name, new_entity)
    end)

    :ok
  end

  defp canonicalize_one(_graph_name, %{embedding: []}), do: :ok
  defp canonicalize_one(_graph_name, %{embedding: nil}), do: :ok

  defp canonicalize_one(graph_name, %{embedding: embedding} = new_entity)
       when is_list(embedding) do
    case Magus.Graph.Vector.knn_search(
           graph_name,
           "Entity",
           "embedding",
           embedding,
           k: @canonicalize_knn_k
         ) do
      {:ok, hits} ->
        hits
        |> filter_canonicalize_candidates(new_entity)
        |> Enum.each(fn match -> merge_pair(graph_name, new_entity, match) end)

      {:error, reason} ->
        Logger.debug(
          "Super Brain canonicalize knn_search failed in #{graph_name}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp canonicalize_one(_graph_name, _entity), do: :ok

  defp filter_canonicalize_candidates(hits, new_entity) do
    new_type = new_entity.type
    new_subtype = new_entity.normalized_subtype

    Enum.filter(hits, fn hit ->
      hit_id = Map.get(hit, :id) || Map.get(hit, "id")
      # FalkorDB's `db.idx.vector.queryNodes` returns cosine DISTANCE
      # (0 = identical, 1 = orthogonal), so we invert to similarity before
      # comparing against the canonicalize threshold.
      hit_distance = FalkorValues.parse_number(Map.get(hit, :score) || Map.get(hit, "score"), 1.0)
      hit_similarity = max(0.0, 1.0 - hit_distance)
      hit_type = Map.get(hit, :type) || Map.get(hit, "type")
      hit_subtype = Map.get(hit, :normalized_subtype) || Map.get(hit, "normalized_subtype")
      hit_extractor = Map.get(hit, :extractor) || Map.get(hit, "extractor")

      hit_id != nil and
        hit_id != new_entity.id and
        hit_similarity >= @canonicalize_similarity_threshold and
        hit_type == new_type and
        same_subtype?(hit_subtype, new_subtype) and
        not curated?(hit_extractor) and
        not curated?(new_entity.extractor)
    end)
  end

  defp same_subtype?(a, a), do: true
  defp same_subtype?(nil, ""), do: true
  defp same_subtype?("", nil), do: true
  defp same_subtype?(_, _), do: false

  defp curated?(nil), do: false

  defp curated?(extractor) when is_binary(extractor),
    do: Enum.any?(@curated_extractor_prefixes, &String.starts_with?(extractor, &1))

  defp curated?(_), do: false

  defp merge_pair(graph_name, new_entity, match) do
    match_id = Map.get(match, :id) || Map.get(match, "id")

    match_confidence =
      FalkorValues.parse_number(
        Map.get(match, :confidence) || Map.get(match, "confidence"),
        0.0
      )

    match_name = Map.get(match, :name) || Map.get(match, "name") || ""
    # Convert FalkorDB cosine distance to similarity for the audit row so
    # downstream analysis reads a value comparable to the threshold.
    distance =
      FalkorValues.parse_number(Map.get(match, :score) || Map.get(match, "score"), 1.0)

    similarity = max(0.0, 1.0 - distance)

    {winner_id, loser_id} =
      pick_winner(new_entity, match_id, match_confidence, match_name)

    case do_merge(graph_name, winner_id, loser_id) do
      :ok ->
        record_canonicalization_event(graph_name, winner_id, loser_id, similarity)
        :ok

      {:error, reason} ->
        Logger.warning("Canonicalize merge failed in #{graph_name}: #{inspect(reason)}")
        :ok
    end
  end

  # Winner-selection precedence (deterministic so concurrent extractions
  # converge on the same merge outcome):
  #   1) higher confidence
  #   2) longer name (tie-break for similar confidence)
  #   3) lexicographically greater id (final deterministic tie-break)
  defp pick_winner(new_entity, match_id, match_confidence, match_name) do
    new_name_len = String.length(new_entity.name || "")
    match_name_len = String.length(match_name)

    cond do
      new_entity.confidence > match_confidence -> {new_entity.id, match_id}
      new_entity.confidence < match_confidence -> {match_id, new_entity.id}
      new_name_len > match_name_len -> {new_entity.id, match_id}
      new_name_len < match_name_len -> {match_id, new_entity.id}
      new_entity.id > match_id -> {new_entity.id, match_id}
      true -> {match_id, new_entity.id}
    end
  end

  # Re-point loser's edges onto winner, then DETACH DELETE the loser.
  #
  # We enumerate the loser's incident edges, MERGE the equivalent edge onto
  # the winner with the same relation type, and copy the loser-side
  # properties we care about (`predicate`, `confidence`, `trust_tier`,
  # `extractor`, `source_id`) using a conflict-aware SET:
  #
  #   * `predicate` and `trust_tier` use `coalesce` so an existing winner
  #     edge's value wins over a loser duplicate that re-establishes the
  #     same relationship.
  #   * `confidence` uses `max` so the more-confident source wins.
  #   * `extractor` / `source_id` `coalesce` to whatever was there first,
  #     preserving provenance of the originally-extracted edge.
  #
  # This is idempotent and parallel-edge safe (same as the previous bare
  # MERGE), while preventing the silent property loss bug where every
  # canonicalize merge stripped `predicate`/`confidence`/`trust_tier` off
  # the surviving edge.
  defp do_merge(graph_name, winner_id, loser_id) do
    outgoing_query = """
    MATCH (loser:Entity {id: $loser_id})-[r]->(other)
    RETURN type(r) AS rel_type, other.id AS other_id,
           r.predicate AS predicate, r.confidence AS confidence,
           r.trust_tier AS trust_tier, r.extractor AS extractor,
           r.source_id AS source_id
    """

    incoming_query = """
    MATCH (other)-[r]->(loser:Entity {id: $loser_id})
    RETURN type(r) AS rel_type, other.id AS other_id,
           r.predicate AS predicate, r.confidence AS confidence,
           r.trust_tier AS trust_tier, r.extractor AS extractor,
           r.source_id AS source_id
    """

    with {:ok, %{rows: outgoing_rows}} <-
           Magus.Graph.query(graph_name, outgoing_query, %{loser_id: loser_id}),
         {:ok, %{rows: incoming_rows}} <-
           Magus.Graph.query(graph_name, incoming_query, %{loser_id: loser_id}) do
      Enum.each(outgoing_rows, fn row ->
        repoint_edge(graph_name, :outgoing, winner_id, row)
      end)

      Enum.each(incoming_rows, fn row ->
        repoint_edge(graph_name, :incoming, winner_id, row)
      end)

      case Magus.Graph.query(
             graph_name,
             "MATCH (loser:Entity {id: $id}) DETACH DELETE loser",
             %{id: loser_id}
           ) do
        {:ok, _} -> :ok
        err -> err
      end
    end
  end

  defp repoint_edge(graph_name, direction, winner_id, [
         rel_type,
         other_id,
         predicate,
         confidence,
         trust_tier,
         extractor,
         source_id
       ]) do
    safe_rel_type = escape_label(rel_type)

    if safe_rel_type == "" do
      # Defensive guard: a label that escapes to empty would produce an
      # invalid Cypher MERGE pattern (`(w)-[r2:]->(o)`). Drop the repoint
      # so the merge step doesn't crash; the loser's incident edge will
      # be DETACH DELETEd along with the loser anyway.
      Logger.warning(
        "Super Brain canonicalize: dropping repoint with empty rel_type " <>
          "(rel_type=#{inspect(rel_type)})"
      )

      {:error, :bad_label}
    else
      merge_pattern =
        case direction do
          :outgoing -> "(w)-[r2:#{safe_rel_type}]->(o)"
          :incoming -> "(o)-[r2:#{safe_rel_type}]->(w)"
        end

      cypher = """
      MATCH (w:Entity {id: $w}), (o {id: $o})
      MERGE #{merge_pattern}
      ON CREATE SET r2.predicate = $predicate,
                    r2.confidence = $confidence,
                    r2.trust_tier = $trust_tier,
                    r2.extractor = $extractor,
                    r2.source_id = $source_id
      ON MATCH SET r2.predicate = coalesce(r2.predicate, $predicate),
                   r2.confidence = CASE
                                     WHEN r2.confidence IS NULL THEN $confidence
                                     WHEN $confidence IS NULL THEN r2.confidence
                                     WHEN $confidence > r2.confidence THEN $confidence
                                     ELSE r2.confidence
                                   END,
                   r2.trust_tier = coalesce(r2.trust_tier, $trust_tier),
                   r2.extractor = coalesce(r2.extractor, $extractor),
                   r2.source_id = coalesce(r2.source_id, $source_id)
      """

      Magus.Graph.query(graph_name, cypher, %{
        w: winner_id,
        o: other_id,
        predicate: predicate,
        confidence: confidence,
        trust_tier: trust_tier,
        extractor: extractor,
        source_id: source_id
      })
    end
  end

  # FalkorDB relation labels are alphanumeric + underscore. Strip anything
  # else to defang accidentally-malformed type names (we never expect to
  # see them in practice since labels come from our own writes, but this
  # is a belt-and-suspenders check against injection through the
  # interpolated label). Use an explicit `[A-Za-z0-9_]` range rather than
  # a case-insensitive `[A-Z_0-9]` so the regex semantics are unambiguous
  # (the previous `i` flag and `[A-Z_0-9]` were equivalent but easy to
  # misread).
  defp escape_label(label) when is_binary(label) do
    String.replace(label, ~r/[^A-Za-z0-9_]/, "")
  end

  defp escape_label(_), do: ""

  # Best-effort audit insert. MUST NOT abort the surrounding transaction:
  # the pipeline runs inside `Repo.transaction`, and any raise OR
  # statement-level error here would roll back the new Episode row + budget
  # atomic_increment, leaving the already-committed FalkorDB writes (Entity
  # nodes + edges + Episode node) orphaned. The audit row is an
  # observability artifact, not load-bearing.
  #
  # Postgres marks the whole transaction as aborted on any statement-level
  # error, so just catching `{:error, _}` from `Repo.query/2` is not enough:
  # subsequent statements (`mark_extracted` etc.) would then fail with
  # "current transaction is aborted". We manually wrap the insert in a
  # SAVEPOINT and `ROLLBACK TO SAVEPOINT` on failure so the surrounding
  # transaction stays in a usable state. We use an explicit SAVEPOINT
  # instead of a nested `Repo.transaction/1` because the latter raises
  # control-flow exceptions on `Repo.rollback/1` that interact poorly with
  # the Oban worker's tx wrapper.
  defp record_canonicalization_event(graph_name, winner_id, loser_id, similarity) do
    savepoint = "sb_audit_#{System.unique_integer([:positive])}"

    case Repo.query("SAVEPOINT #{savepoint}", []) do
      {:ok, _} ->
        case Repo.query(
               """
               INSERT INTO super_brain_canonicalization_events
                 (id, graph_name, winner_id, loser_id, similarity, reason, extractor_version, inserted_at)
               VALUES (gen_random_uuid(), $1, $2, $3, $4, $5, $6, NOW())
               """,
               [
                 graph_name,
                 winner_id,
                 loser_id,
                 similarity,
                 "inline_extract",
                 @inline_canonicalize_version
               ]
             ) do
          {:ok, _} ->
            _ = Repo.query("RELEASE SAVEPOINT #{savepoint}", [])
            :ok

          {:error, reason} ->
            Logger.warning(
              "super_brain: canonicalization audit insert failed: #{inspect(reason)}"
            )

            # Roll back to BEFORE the failed insert so the outer
            # transaction stays healthy and `mark_extracted` (etc.)
            # can still commit.
            _ = Repo.query("ROLLBACK TO SAVEPOINT #{savepoint}", [])
            _ = Repo.query("RELEASE SAVEPOINT #{savepoint}", [])
            :ok
        end

      {:error, reason} ->
        Logger.warning("super_brain: canonicalization audit savepoint failed: #{inspect(reason)}")

        :ok
    end
  end

  # Build the descriptor passed into `canonicalize_inline/2`. We carry only
  # the fields the canonicalize filter needs so the data flows cleanly
  # without re-querying FalkorDB.
  defp entity_descriptor(graph_name, entity, embedding, extractor_version) do
    %{
      id: stable_id(graph_name, entity.name, entity.type),
      name: entity.name,
      type: Atom.to_string(entity.type),
      normalized_subtype: SubtypeNormalizer.normalize(entity.subtype),
      embedding: embedding,
      confidence: entity.confidence,
      extractor: extractor_version
    }
  end

  defp write_has_entity_edge(graph_name, episode_id, entity, extractor_version) do
    Magus.Graph.upsert_edge(
      graph_name,
      %{
        from_label: "Episode",
        from_id: episode_id,
        to_label: "Entity",
        to_id: stable_id(graph_name, entity.name, entity.type)
      },
      "HAS_ENTITY",
      %{
        confidence: entity.confidence,
        extracted_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        extractor: extractor_version,
        source_id: episode_id
      }
    )
  end

  # ---------------------------------------------------------------------------
  # Embedding helpers
  #
  # Both helpers FAIL LOUD when the embedder errors: returning
  # `{:error, :embedder_unavailable}` propagates through the `with` chain
  # in `write_to_graph/4` and surfaces as an Oban worker failure with
  # automatic retry/backoff. Previously these degraded to empty embeddings,
  # which silently wrote entities without vectors. Those entities then
  # became permanently invisible to KNN, and the fingerprint gate would
  # prevent re-extraction from healing them.
  # ---------------------------------------------------------------------------

  defp embed_text(nil), do: {:ok, []}
  defp embed_text(""), do: {:ok, []}

  defp embed_text(text) when is_binary(text) do
    case extraction_embedder().embed_one(clip_text(text, @episode_raw_text_max)) do
      {:ok, embedding} when is_list(embedding) ->
        {:ok, embedding}

      {:error, reason} ->
        Logger.warning(
          "Super Brain embed_one failed; failing extraction so Oban retries: #{inspect(reason)}"
        )

        SBTelemetry.embedder_failure(reason)
        {:error, :embedder_unavailable}
    end
  end

  defp embed_entities([]), do: {:ok, []}

  defp embed_entities(entities) do
    names = Enum.map(entities, & &1.name)

    case extraction_embedder().embed_many(names) do
      {:ok, embeddings} when length(embeddings) == length(names) ->
        {:ok, Enum.zip(entities, embeddings)}

      {:ok, embeddings} ->
        Logger.warning(
          "Super Brain embed_many returned #{length(embeddings)} embeddings for #{length(names)} names; failing extraction so Oban retries"
        )

        SBTelemetry.embedder_failure({:length_mismatch, length(embeddings), length(names)})
        {:error, :embedder_unavailable}

      {:error, reason} ->
        Logger.warning(
          "Super Brain embed_many failed; failing extraction so Oban retries: #{inspect(reason)}"
        )

        SBTelemetry.embedder_failure(reason)
        {:error, :embedder_unavailable}
    end
  end

  defp extraction_embedder do
    Application.fetch_env!(:magus, :super_brain_extraction_embedder)
  end

  defp maybe_put_embedding(map, []), do: map

  defp maybe_put_embedding(map, embedding) when is_list(embedding),
    do: Map.put(map, :embedding, embedding)

  defp clip_text(nil, _max), do: ""

  # `binary_part/3` truncates at a byte offset, which can split a multibyte
  # UTF-8 character and leave a dangling lead byte (e.g. 0xE2). That invalid
  # binary blows up `Jason.encode` when the clipped raw_text is later written
  # to FalkorDB. `String.replace_invalid/1` rewrites any dangling bytes to the
  # Unicode replacement char so the slice is always valid UTF-8.
  defp clip_text(s, max) when is_binary(s) and byte_size(s) > max,
    do: s |> binary_part(0, max) |> String.replace_invalid()

  defp clip_text(s, _max) when is_binary(s), do: s

  # The sanitiser normalises predicates to existing atoms (canonical or
  # known free-form) or keeps them as binaries. Handle both shapes when
  # serialising for storage.
  defp predicate_to_string(p) when is_atom(p), do: Atom.to_string(p)
  defp predicate_to_string(p) when is_binary(p), do: p

  # Stable, deterministic node id per (graph, type, lowercased name). Used
  # so repeated extractions of the same entity converge on the same node
  # via MERGE, and edge subject/object lookups find them without a join on
  # name. Hash to 32 hex chars (128 bits) which is plenty of collision room
  # within a single brain.
  #
  # Type IS part of the id (Task 3.4): pre-iter5 the hash was
  # `(graph_name, downcase(name))` only, so "Apple" the organization and
  # "apple" the food collided onto a single FalkorDB node and the `type`
  # property thrashed on every re-extraction. The sanitizer's
  # entity-name filter on edges plus a per-extraction `name -> type`
  # lookup in `build_entity_type_lookup/2` keeps RELATES_TO endpoint
  # resolution stable: every edge endpoint is guaranteed to appear in
  # the entities list, so its type is known at edge-write time. The
  # rare same-name-different-type-in-one-extraction case falls back to
  # the first occurrence and emits a telemetry counter.
  defp stable_id(graph_name, name, type) do
    name_key = name |> to_string() |> String.downcase()
    payload = "#{graph_name}|#{type_key(type)}|#{name_key}"

    :crypto.hash(:sha256, payload)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  # Normalize an entity type into a stable string component for the
  # stable_id hash. `nil` becomes `"__none__"` (matching iter4's subtype
  # sentinel convention). Atoms become their lowercased string form (the
  # sanitizer constrains types to a known canonical atom set, so this
  # cannot mint new atoms or admit user-controlled values). Strings (FOR
  # example a type already loaded from a FalkorDB property) are lowercased
  # as-is.
  defp type_key(nil), do: "__none__"
  defp type_key(type) when is_atom(type), do: type |> Atom.to_string() |> String.downcase()
  defp type_key(type) when is_binary(type), do: String.downcase(type)
  defp type_key(other), do: other |> inspect() |> String.downcase()

  # Build a `name -> type` lookup so RELATES_TO endpoints can be resolved
  # to the same `stable_id(graph_name, name, type)` used for the Entity
  # nodes. The sanitizer drops edges whose subject_name/object_name aren't
  # in the entities list, so the lookup is guaranteed to have a hit at
  # edge-write time.
  #
  # Same-name-different-type within a single extraction is rare but
  # technically possible (the LLM emits "Apple/organization" and
  # "Apple/food" in one pass). The edge alone cannot disambiguate which
  # endpoint was meant, so we emit a telemetry counter for observability
  # and fall back to the first occurrence. The user can clean this up in a
  # later extraction by giving each entity a subtype, splitting them into
  # different episodes, or accepting the first-occurrence binding.
  defp build_entity_type_lookup(entities_with_embeddings, graph_name) do
    Enum.reduce(entities_with_embeddings, %{}, fn {entity, _embedding}, acc ->
      case Map.fetch(acc, entity.name) do
        :error ->
          Map.put(acc, entity.name, entity.type)

        {:ok, existing_type} when existing_type == entity.type ->
          acc

        {:ok, existing_type} ->
          :telemetry.execute(
            [:super_brain, :sanitizer, :ambiguous_edge_endpoint],
            %{count: 1},
            %{
              graph_name: graph_name,
              name: entity.name,
              kept_type: existing_type,
              dropped_type: entity.type
            }
          )

          Logger.warning(
            "super_brain: ambiguous edge endpoint #{inspect(entity.name)} appears with " <>
              "types #{inspect(existing_type)} and #{inspect(entity.type)} in graph " <>
              "#{graph_name}; keeping first-occurrence type for edge resolution"
          )

          acc
      end
    end)
  end
end
