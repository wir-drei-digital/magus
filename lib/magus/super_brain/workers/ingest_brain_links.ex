defmodule Magus.SuperBrain.Workers.IngestBrainLinks do
  @moduledoc """
  Materializes a brain page's `[[wikilinks]]` into the brain's FalkorDB graph
  as `:instruction`-tier `:mentions` edges between the pages' `document`
  entities.

  A `[[Page Name]]` link is a strong, user-declared "A relates to B" signal.
  The markdown save pipeline already maintains a `brain_page_links` index
  (`Magus.Brain.list_forward_links/1`); this worker consumes it so links reach
  the Super Brain deterministically rather than depending on the LLM noticing
  the `[[...]]` syntax. It complements `IngestBrainPin` (explicit *typed* pins
  like `supports` / `contradicts`) and restores the automatic half of the
  deleted `Brain.Connection` path.

  Durability mirrors `IngestBrainPin`: an append-only
  `Magus.SuperBrain.Episode` (`resource_type: :brain_links`,
  `resource_id = page_id`) is the source of truth; the FalkorDB nodes/edges
  are derived (`source_id = episode.id`). Re-running on each save supersedes
  the page's prior links episode, which is how add/remove is handled (the
  page's whole edge set is replaced). `source_weight` is `1.0` (a notch below
  pins' `1.5`: links are ambient, pins are deliberate).

  Self-contained (does not route through the LLM `ExtractBase` pipeline).
  Link entities carry the `brain_links_ingest` extractor prefix so inline
  canonicalize in `ExtractBase` never merges them.

  Concurrent jobs for the same `page_id` are serialized by a
  transaction-scoped `pg_advisory_xact_lock` (plus the Oban `unique`
  enqueue-time dedup), mirroring `IngestBrainPin`. Because page bodies churn
  on every save, a fingerprint gate over the canonical sorted target-page-id
  list short-circuits redundant work before the lock is taken: if the prior
  `:extracted` `:brain_links` episode for the page has the same
  `content_fingerprint`, the job is a no-op.
  """

  use Oban.Worker,
    queue: :super_brain_extraction,
    max_attempts: 5,
    unique: [period: 60, fields: [:args]]

  alias Magus.SuperBrain.{AccessibleGraphs, EmbeddingConfig, Episode}
  alias Magus.SuperBrain.Workers.BuildSuperIncremental

  require Ash.Query
  require Logger

  @extractor_version "brain_links_ingest@2026-06-02"
  @predicate "mentions"

  @doc false
  def extractor_version, do: @extractor_version

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    if Magus.SuperBrain.enabled?(),
      do: route(job),
      else: {:cancel, :super_brain_disabled}
  end

  # Accept both `page_id` (the live `update_body` enqueue) and `resource_id`
  # (the `mix super_brain.rebuild` replay, which dispatches every episode type
  # by `resource_id`). Both are the brain page id.
  defp route(%Oban.Job{args: %{"page_id" => page_id}}) when is_binary(page_id),
    do: do_perform(page_id)

  defp route(%Oban.Job{args: %{"resource_id" => page_id}}) when is_binary(page_id),
    do: do_perform(page_id)

  defp route(%Oban.Job{args: _}), do: {:error, :missing_page_id}

  defp do_perform(page_id) do
    with {:ok, page} <- Ash.get(Magus.Brain.Page, page_id, load: [:brain], authorize?: false),
         {:ok, user_id} <- resolve_user_id(page),
         :ok <- have_title(page) do
      graph_name = "brain:#{page.brain_id}"
      targets = resolve_targets(page)

      case ingest(graph_name, page, targets, user_id) do
        :ok ->
          fan_out(graph_name)
          :ok

        {:error, reason} = err ->
          Logger.warning("IngestBrainLinks failed (page #{page_id}): #{inspect(reason)}")
          err
      end
    else
      {:error, %Ash.Error.Query.NotFound{}} ->
        # The source page was deleted between enqueue and perform; nothing to
        # do. Treat as a successful no-op so Oban does not retry forever.
        :ok

      {:error, reason} = err ->
        Logger.warning("IngestBrainLinks failed (page #{page_id}): #{inspect(reason)}")
        err
    end
  end

  # Resolve the page's forward links (the `brain_page_links` index) into the
  # current target pages. Skips: self-links, and targets that no longer exist /
  # are trashed (the default `read` action filters `is_nil(deleted_at)`, so a
  # trashed or deleted target returns NotFound) / have a blank title.
  defp resolve_targets(page) do
    case Magus.Brain.list_forward_links(page.id, authorize?: false) do
      {:ok, links} ->
        links
        |> Enum.map(& &1.target_page_id)
        |> Enum.uniq()
        |> Enum.reject(&(&1 == page.id))
        |> Enum.flat_map(fn target_id ->
          case Ash.get(Magus.Brain.Page, target_id, authorize?: false) do
            {:ok, %{title: t} = target} when is_binary(t) and t != "" -> [target]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  # Serialize concurrent jobs for the same page with a transaction-scoped
  # advisory lock (mirrors `IngestBrainPin`). The fingerprint gate runs first,
  # OUTSIDE the lock, so an unchanged save costs at most one read and never
  # takes the lock or rewrites the graph.
  defp ingest(graph_name, page, targets, user_id) do
    resource_id = page.id
    raw_text = canonical_raw_text(targets)

    if fingerprint_unchanged?(resource_id, raw_text) do
      :ok
    else
      Magus.Repo.transaction(fn ->
        acquire_lock(resource_id)
        do_ingest(graph_name, page, targets, raw_text, user_id)
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:ok, {:error, reason}} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Skip redundant work when the page's resolved link set is unchanged since
  # the last `:extracted` episode. Mirrors `ExtractBase.gate_on_fingerprint/3`:
  # filter to `status == :extracted` so the (append-only) episode history with
  # many `:superseded` rows never trips `read_one`'s multiple-results guard.
  defp fingerprint_unchanged?(resource_id, raw_text) do
    new_fingerprint = :crypto.hash(:sha256, raw_text)

    case Episode
         |> Ash.Query.filter(
           resource_type == :brain_links and resource_id == ^resource_id and status == :extracted
         )
         |> Ash.read_one(authorize?: false) do
      {:ok, %Episode{content_fingerprint: ^new_fingerprint}} -> true
      _ -> false
    end
  end

  defp do_ingest(graph_name, page, targets, raw_text, user_id) do
    with :ok <- ensure_index(graph_name),
         :ok <- supersede_prior(graph_name, page.id) do
      # No targets after superseding the prior episode: the page's prior edges
      # are already removed, so stop without creating a new (empty) episode.
      if targets == [] do
        :ok
      else
        write_links(graph_name, page, targets, raw_text, user_id)
      end
    end
  end

  defp write_links(graph_name, page, targets, raw_text, user_id) do
    with {:ok, episode} <- create_episode(graph_name, page, targets, raw_text, user_id),
         {:ok, src_props} <- entity_props(graph_name, page, episode.id),
         :ok <- write_episode_node(graph_name, episode, user_id),
         :ok <- upsert_entity(graph_name, src_props),
         :ok <- write_has_entity(graph_name, episode.id, src_props),
         :ok <- write_targets(graph_name, episode.id, src_props, targets),
         {:ok, _} <- mark_extracted(episode) do
      :ok
    end
  end

  # Write each target `document` entity, its `HAS_ENTITY` edge from the
  # episode, and the source -[:mentions]-> target `RELATES_TO` edge. Stops at
  # the first error so Oban retries from a known state (the episode is left
  # `:pending` and the next run supersedes it).
  defp write_targets(graph_name, episode_id, src_props, targets) do
    Enum.reduce_while(targets, :ok, fn target, :ok ->
      with {:ok, tgt_props} <- entity_props(graph_name, target, episode_id),
           :ok <- upsert_entity(graph_name, tgt_props),
           :ok <- write_has_entity(graph_name, episode_id, tgt_props),
           :ok <- write_edge(graph_name, src_props, tgt_props, episode_id) do
        {:cont, :ok}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # `pg_advisory_xact_lock(bigint)` keyed on the page id; auto-released at
  # transaction end. Advisory locks are re-entrant per session, so a re-run
  # within the same DB connection (e.g. tests) does not deadlock.
  defp acquire_lock(page_id) do
    payload = "super_brain_extraction|brain_links|#{page_id}"
    <<key::signed-integer-size(64), _rest::binary>> = :crypto.hash(:sha256, payload)
    Magus.Repo.query!("SELECT pg_advisory_xact_lock($1)", [key])
    :ok
  end

  # --- validation -----------------------------------------------------------

  defp resolve_user_id(%Magus.Brain.Page{brain: %{user_id: user_id}})
       when is_binary(user_id),
       do: {:ok, user_id}

  defp resolve_user_id(_), do: {:error, :page_user_not_resolvable}

  defp have_title(%{title: t}) when is_binary(t) and t != "", do: :ok
  defp have_title(_), do: {:error, :page_missing_title}

  # Canonical, deterministic text over the SORTED target page ids so the
  # fingerprint is stable regardless of link order in the body and so an
  # add/remove flips the fingerprint.
  defp canonical_raw_text(targets) do
    targets
    |> Enum.map(& &1.id)
    |> Enum.sort()
    |> Enum.join(",")
  end

  # --- episode lifecycle ----------------------------------------------------

  defp create_episode(graph_name, page, targets, raw_text, user_id) do
    Episode
    |> Ash.Changeset.for_create(
      :create,
      %{
        resource_type: :brain_links,
        resource_id: page.id,
        graph_name: graph_name,
        raw_text: raw_text,
        source_user_id: user_id,
        source_weight: 1.0,
        extractor_version: @extractor_version,
        # Persist the source page id and the resolved target titles so
        # `mix super_brain.rebuild` has human-readable replay context.
        # `resource_id` already carries the page id, so the rebuild re-reads
        # `brain_page_links` directly rather than relying on this.
        metadata: %{
          "source_page_id" => page.id,
          "target_titles" => Enum.map(targets, & &1.title)
        }
      },
      actor: %{id: user_id}
    )
    |> Ash.create(actor: %{id: user_id})
  end

  defp supersede_prior(graph_name, resource_id) do
    case Episode
         |> Ash.Query.filter(
           resource_type == :brain_links and resource_id == ^resource_id and
             status in [:pending, :processing, :extracted, :failed]
         )
         |> Ash.read(authorize?: false) do
      {:ok, priors} ->
        Enum.each(priors, fn prior ->
          _ = delete_prior_graph(graph_name, prior.id)

          _ =
            Ash.update(prior, %{}, action: :supersede, actor: %{id: prior.source_user_id})
        end)

        :ok

      _ ->
        :ok
    end
  end

  # Remove the prior episode's full graph footprint. Unlike `IngestBrainPin`
  # (whose single edge always has the same endpoints and is simply overwritten
  # by the next MERGE), a page's link *set* changes between saves: a removed
  # `[[Gamma]]` leaves a stale `Alpha -[:mentions]-> Gamma` edge that the new
  # episode never rewrites. So we explicitly delete the prior episode's tagged
  # `RELATES_TO` edges by `source_id` BEFORE the orphan-entity sweep, then drop
  # any entity the supersede orphaned (e.g. a target no longer linked by any
  # episode). The `document` entities that the new episode re-links are
  # re-MERGEd afterward by `write_links/5`, so deleting them here is safe.
  defp delete_prior_graph(graph_name, episode_id) do
    _ =
      Magus.Graph.query(
        graph_name,
        "MATCH (ep:Episode {source_id: $sid}) DETACH DELETE ep",
        %{sid: episode_id}
      )

    _ =
      Magus.Graph.query(
        graph_name,
        "MATCH (:Entity)-[r:RELATES_TO {source_id: $sid}]->(:Entity) DELETE r",
        %{sid: episode_id}
      )

    _ =
      Magus.Graph.query(
        graph_name,
        """
        MATCH (e:Entity {source_id: $sid})
        WHERE NOT EXISTS((:Episode)-[:HAS_ENTITY]->(e))
        DETACH DELETE e
        """,
        %{sid: episode_id}
      )

    :ok
  end

  defp mark_extracted(episode) do
    Ash.update(episode, %{}, action: :mark_extracted, actor: %{id: episode.source_user_id})
  end

  # --- graph writes ---------------------------------------------------------

  defp ensure_index(graph_name) do
    _ =
      Magus.Graph.Vector.ensure_index(graph_name, "Entity", "embedding",
        dim: EmbeddingConfig.dim(),
        similarity: :cosine
      )

    :ok
  end

  defp entity_props(graph_name, %{id: page_id, title: title}, episode_id) do
    base = %{
      id: stable_id(graph_name, title, "document"),
      name: title,
      type: "document",
      subtype: nil,
      normalized_subtype: nil,
      confidence: 1.0,
      trust_tier: "instruction",
      extractor: @extractor_version,
      source_id: episode_id,
      page_id: page_id
    }

    case Application.fetch_env!(:magus, :super_brain_extraction_embedder).embed_one(title) do
      {:ok, embedding} when is_list(embedding) ->
        {:ok, Map.put(base, :embedding, embedding)}

      {:error, reason} ->
        Logger.warning(
          "IngestBrainLinks embedding for page #{page_id} failed: #{inspect(reason)}"
        )

        {:error, :embedder_unavailable}
    end
  end

  defp write_episode_node(graph_name, episode, user_id) do
    props = %{
      id: episode.id,
      resource_type: "brain_links",
      resource_id: episode.resource_id,
      raw_text: episode.raw_text,
      source_user_id: user_id,
      source_weight: 1.0,
      extractor: @extractor_version,
      occurred_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      source_id: episode.id
    }

    case Magus.Graph.upsert_node(graph_name, "Episode", props) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp upsert_entity(graph_name, props) do
    case Magus.Graph.upsert_node(graph_name, "Entity", props) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp write_has_entity(graph_name, episode_id, entity_props) do
    case Magus.Graph.upsert_edge(
           graph_name,
           %{
             from_label: "Episode",
             from_id: episode_id,
             to_label: "Entity",
             to_id: entity_props.id
           },
           "HAS_ENTITY",
           %{
             confidence: 1.0,
             extracted_at: DateTime.utc_now() |> DateTime.to_iso8601(),
             extractor: @extractor_version,
             source_id: episode_id
           }
         ) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp write_edge(graph_name, src_props, tgt_props, episode_id) do
    case Magus.Graph.upsert_edge(
           graph_name,
           %{
             from_label: "Entity",
             from_id: src_props.id,
             to_label: "Entity",
             to_id: tgt_props.id
           },
           "RELATES_TO",
           %{
             predicate: @predicate,
             confidence: 1.0,
             trust_tier: "instruction",
             extractor: @extractor_version,
             source_id: episode_id
           }
         ) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  # --- fan-out --------------------------------------------------------------

  defp fan_out(graph_name) do
    graph_name
    |> AccessibleGraphs.accessors_of()
    |> Enum.each(fn accessor ->
      %{
        "accessor_type" => Atom.to_string(accessor.type),
        "user_id" => accessor.user_id,
        "workspace_id" => accessor.workspace_id
      }
      |> BuildSuperIncremental.new()
      |> Oban.insert()
    end)

    :ok
  end

  # --- stable id (mirrors ExtractBase.stable_id/3) --------------------------

  defp stable_id(graph_name, name, type) do
    name_key = name |> to_string() |> String.downcase()
    type_key = type |> to_string() |> String.downcase()

    :crypto.hash(:sha256, "#{graph_name}|#{type_key}|#{name_key}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end
end
