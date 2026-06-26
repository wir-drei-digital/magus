defmodule Magus.Brain.PageChunk do
  @moduledoc """
  Per-chunk embeddings of `Magus.Brain.Page` bodies.

  Phase A defines the resource and table only; nothing reads or writes it
  yet. The backfill Oban worker, the per-save chunker, and the
  `generate_embedding` trigger arrive in Phase B/C.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Brain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOban],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "brain_page_chunks"
    repo Magus.Repo

    references do
      reference :page, on_delete: :delete
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

    read :for_page do
      argument :page_id, :uuid, allow_nil?: false
      filter expr(page_id == ^arg(:page_id))
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
        |> Ash.Query.filter(exists(page, brain_id == ^brain_id))
        |> Ash.Query.load([:page, vector_distance: calc_args])
        |> Ash.Query.sort({:vector_distance, {calc_args, :asc}})
        |> Ash.Query.limit(limit_val)
      end
    end

    create :create do
      accept [:page_id, :index, :content, :token_count, :embedding]
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
      authorize_if {Magus.Brain.Checks.BrainAccessFilter, path: :via_page, min_role: :viewer}
    end

    # Writes (including the `:destroy` default) only happen via internal
    # pipelines (backfill workers, save after-actions) running with
    # `authorize?: false`. The default destroy is kept so cascade cleanup
    # paths have an action to call; the unconditional forbid is intentional
    # for any caller passing an `actor:` so accidental user-facing writes
    # fail loud. Same pattern as `Magus.Files.Chunk`.
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
    belongs_to :page, Magus.Brain.Page, allow_nil?: false
  end

  calculations do
    calculate :vector_distance, :float do
      argument :query_embedding, {:array, :float}, allow_nil?: false
      calculation expr(fragment("(embedding <=> ?::vector)", ^arg(:query_embedding)))
    end
  end

  identities do
    identity :unique_page_index, [:page_id, :index]
  end
end
