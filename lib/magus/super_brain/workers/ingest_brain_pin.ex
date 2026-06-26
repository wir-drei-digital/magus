defmodule Magus.SuperBrain.Workers.IngestBrainPin do
  @moduledoc """
  Materializes a user-pinned, high-confidence relationship between two
  brain pages into the brain's FalkorDB graph at `:instruction` trust tier.

  Replaces the deleted `Brain.Connection` path. Durability is via an
  append-only `Magus.SuperBrain.Episode` (`resource_type: :brain_pin`): the
  Postgres episode is the source of truth, the FalkorDB nodes/edges are
  derived (`source_id = episode.id`). Re-pinning the same
  `(source, predicate, target)` triple supersedes the prior pin episode.

  Self-contained (does not route through the LLM `ExtractBase` pipeline).
  Pinned nodes carry the `brain_pin_ingest` extractor prefix so inline
  canonicalize in `ExtractBase` never merges them.

  Concurrent jobs for the same `(source, predicate, target)` triple are
  serialized by a transaction-scoped `pg_advisory_xact_lock` (plus the Oban
  `unique` enqueue-time dedup), mirroring `ExtractBase`. The FalkorDB writes
  are external to the Postgres transaction but idempotent (MERGE on id); a job
  that crashes mid-sequence leaves a `:pending` episode that the next retry or
  re-pin supersedes, so the pin self-heals.
  """

  use Oban.Worker,
    queue: :super_brain_extraction,
    max_attempts: 5,
    unique: [period: 60, fields: [:args]]

  alias Magus.SuperBrain.{AccessibleGraphs, EmbeddingConfig, Episode}
  alias Magus.SuperBrain.Workers.BuildSuperIncremental

  require Logger

  @extractor_version "brain_pin_ingest@2026-06-01"

  @doc false
  def extractor_version, do: @extractor_version

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    if Magus.SuperBrain.enabled?(),
      do: do_perform(job),
      else: {:cancel, :super_brain_disabled}
  end

  defp do_perform(%Oban.Job{
         args: %{
           "source_page_id" => sid,
           "target_page_id" => tid,
           "predicate" => predicate,
           "user_id" => user_id
         }
       })
       when is_binary(sid) and is_binary(tid) and is_binary(predicate) and is_binary(user_id) do
    with {:ok, source} <- Ash.get(Magus.Brain.Page, sid, authorize?: false),
         {:ok, target} <- Ash.get(Magus.Brain.Page, tid, authorize?: false),
         :ok <- same_brain(source, target),
         :ok <- have_titles(source, target) do
      graph_name = "brain:#{source.brain_id}"
      resource_id = pin_resource_id(sid, predicate, tid)

      case ingest(graph_name, resource_id, source, target, predicate, user_id) do
        :ok ->
          fan_out(graph_name, user_id)
          :ok

        {:error, reason} = err ->
          Logger.warning("IngestBrainPin failed (#{sid} -> #{tid}): #{inspect(reason)}")
          err
      end
    else
      {:error, reason} = err ->
        Logger.warning("IngestBrainPin failed (#{sid} -> #{tid}): #{inspect(reason)}")
        err
    end
  end

  defp do_perform(%Oban.Job{args: _}), do: {:error, :missing_pin_args}

  # Serialize concurrent jobs for the same pin triple with a transaction-scoped
  # advisory lock (mirrors `ExtractBase`). `do_ingest/6` returns plain `:ok` /
  # `{:error, reason}` (no `Repo.rollback`), so the episode lifecycle commits
  # even on a graph-write error and Oban retries from a known state. The lock
  # also makes the `mark_extracted` partial-unique-index conflict unreachable
  # (no concurrent writer can hold a competing `:extracted` row mid-flight).
  defp ingest(graph_name, resource_id, source, target, predicate, user_id) do
    Magus.Repo.transaction(fn ->
      acquire_lock(resource_id)
      do_ingest(graph_name, resource_id, source, target, predicate, user_id)
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_ingest(graph_name, resource_id, source, target, predicate, user_id) do
    with :ok <- ensure_index(graph_name),
         :ok <- supersede_prior(graph_name, resource_id),
         {:ok, episode} <-
           create_episode(graph_name, resource_id, source, target, predicate, user_id),
         {:ok, src_props} <- entity_props(graph_name, source, episode.id),
         {:ok, tgt_props} <- entity_props(graph_name, target, episode.id),
         :ok <- write_episode_node(graph_name, episode, user_id),
         :ok <- upsert_entity(graph_name, src_props),
         :ok <- upsert_entity(graph_name, tgt_props),
         :ok <- write_has_entity(graph_name, episode.id, src_props),
         :ok <- write_has_entity(graph_name, episode.id, tgt_props),
         :ok <- write_edge(graph_name, src_props, tgt_props, predicate, episode.id),
         {:ok, _} <- mark_extracted(episode) do
      :ok
    end
  end

  # `pg_advisory_xact_lock(bigint)` keyed on the pin triple's resource_id;
  # auto-released at transaction end. Advisory locks are re-entrant per session,
  # so a re-pin within the same DB connection (e.g. tests) does not deadlock.
  defp acquire_lock(resource_id) do
    payload = "super_brain_extraction|brain_pin|#{resource_id}"
    <<key::signed-integer-size(64), _rest::binary>> = :crypto.hash(:sha256, payload)
    Magus.Repo.query!("SELECT pg_advisory_xact_lock($1)", [key])
    :ok
  end

  # --- validation -----------------------------------------------------------

  defp same_brain(%{brain_id: b}, %{brain_id: b}), do: :ok
  defp same_brain(_, _), do: {:error, :pages_in_different_brains}

  defp have_titles(%{title: s}, %{title: t})
       when is_binary(s) and s != "" and is_binary(t) and t != "",
       do: :ok

  defp have_titles(_, _), do: {:error, :page_missing_title}

  # Deterministic UUID over the ordered triple so a re-pin of the same
  # relationship supersedes the prior episode.
  defp pin_resource_id(source_id, predicate, target_id) do
    key = "#{source_id}|#{predicate}|#{target_id}"
    <<bin::binary-size(16), _::binary>> = :crypto.hash(:sha256, key)
    {:ok, uuid} = Ecto.UUID.load(bin)
    uuid
  end

  # --- episode lifecycle ----------------------------------------------------

  defp create_episode(graph_name, resource_id, source, target, predicate, user_id) do
    raw_text = "#{source.title} -[#{predicate}]-> #{target.title}"

    Episode
    |> Ash.Changeset.for_create(
      :create,
      %{
        resource_type: :brain_pin,
        resource_id: resource_id,
        graph_name: graph_name,
        raw_text: raw_text,
        source_user_id: user_id,
        source_weight: 1.5,
        extractor_version: @extractor_version,
        # Persist the page triple so `mix super_brain.rebuild` can re-dispatch
        # this pin (resource_id is a one-way hash; raw_text holds titles, not
        # ids). source_user_id already carries the user.
        metadata: %{
          "source_page_id" => source.id,
          "target_page_id" => target.id,
          "predicate" => predicate
        }
      },
      actor: %{id: user_id}
    )
    |> Ash.create(actor: %{id: user_id})
  end

  defp supersede_prior(graph_name, resource_id) do
    require Ash.Query

    case Episode
         |> Ash.Query.filter(
           resource_type == :brain_pin and resource_id == ^resource_id and
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
        Logger.warning("IngestBrainPin embedding for page #{page_id} failed: #{inspect(reason)}")
        {:error, :embedder_unavailable}
    end
  end

  defp write_episode_node(graph_name, episode, user_id) do
    props = %{
      id: episode.id,
      resource_type: "brain_pin",
      resource_id: episode.resource_id,
      raw_text: episode.raw_text,
      source_user_id: user_id,
      source_weight: 1.5,
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

  defp write_edge(graph_name, src_props, tgt_props, predicate, episode_id) do
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
             predicate: predicate,
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

  defp fan_out(graph_name, _user_id) do
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
