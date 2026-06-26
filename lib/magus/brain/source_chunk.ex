defmodule Magus.Brain.SourceChunk do
  @moduledoc """
  Per-chunk embeddings of `Magus.Brain.Source.ingested_content`.

  Mirrors `Magus.Brain.PageChunk` so search across pages and sources can
  be unified. Phase A defines the resource only; Phase B/C add the
  chunker, the per-ingest worker, and the `generate_embedding` trigger.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Brain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOban],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "brain_source_chunks"
    repo Magus.Repo

    references do
      reference :source, on_delete: :delete
    end
  end

  oban do
    triggers do
      trigger :generate_embedding do
        action :generate_embedding
        scheduler_cron "* * * * *"
        queue :brain_embedding
        where expr(is_nil(embedding))
        read_action :read_for_embedding
        worker_read_action :read_for_embedding
        worker_module_name __MODULE__.EmbeddingWorker
        scheduler_module_name __MODULE__.EmbeddingScheduler
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    # Internal read backing the `generate_embedding` Oban trigger. AshOban
    # runs the scheduler and per-record worker reads with `authorize?: true`
    # and `actor: nil` (no actor_persister), so this action must sit in the
    # `always()` bypass below. The policy-gated default `:read` would filter
    # every row out for a nil actor, so zero workers would ever enqueue and
    # chunks would never get embedded.
    read :read_for_embedding do
      pagination keyset?: true, required?: false
    end

    read :for_source do
      argument :source_id, :uuid, allow_nil?: false
      filter expr(source_id == ^arg(:source_id))
      prepare build(sort: [index: :asc])
    end

    read :semantic_search do
      argument :brain_id, :uuid, allow_nil?: false
      argument :query_embedding, {:array, :float}, allow_nil?: false
      argument :limit, :integer, default: 10

      prepare fn query, _context ->
        require Ash.Query

        embedding = Ash.Query.get_argument(query, :query_embedding)
        brain_id = Ash.Query.get_argument(query, :brain_id)
        limit_val = Ash.Query.get_argument(query, :limit)
        calc_args = %{query_embedding: embedding}

        query
        |> Ash.Query.filter(not is_nil(embedding))
        |> Ash.Query.filter(exists(source, brain_id == ^brain_id))
        |> Ash.Query.load([:source, vector_distance: calc_args])
        |> Ash.Query.sort({:vector_distance, {calc_args, :asc}})
        |> Ash.Query.limit(limit_val)
      end
    end

    create :create do
      accept [:source_id, :index, :content, :token_count, :embedding]
    end

    update :update do
      primary? true
      accept [:content, :token_count, :embedding]
    end

    update :generate_embedding do
      accept []
      require_atomic? false
      change Magus.Brain.Changes.GenerateChunkEmbedding
    end
  end

  policies do
    bypass action([:generate_embedding, :read_for_embedding]) do
      authorize_if always()
    end

    bypass action_type(:read) do
      authorize_if Magus.Checks.IsAiAgent
    end

    policy action_type(:read) do
      authorize_if {Magus.Brain.Checks.BrainAccessFilter, path: :via_source, min_role: :viewer}
    end

    # Writes (including the `:destroy` default) only happen via internal
    # pipelines running with `authorize?: false`. The destroy action is
    # kept for cascade cleanup; user-facing writes fail loud.
    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :index, :integer, allow_nil?: false
    attribute :content, :string, allow_nil?: false
    attribute :token_count, :integer
    attribute :embedding, Magus.Files.Types.Vector

    timestamps()
  end

  relationships do
    belongs_to :source, Magus.Brain.Source, allow_nil?: false
  end

  calculations do
    calculate :vector_distance, :float do
      argument :query_embedding, {:array, :float}, allow_nil?: false
      calculation expr(fragment("(embedding <=> ?::vector)", ^arg(:query_embedding)))
    end
  end

  identities do
    identity :unique_source_index, [:source_id, :index]
  end
end
