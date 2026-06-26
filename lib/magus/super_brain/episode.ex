defmodule Magus.SuperBrain.Episode do
  @moduledoc """
  An Episode is one row per piece of source content the Super Brain has tried
  to extract knowledge from.

  Each episode references a source resource (e.g. a brain page, memory, file,
  draft, or message) and tracks the lifecycle of extracting structured
  knowledge from its raw text into the cross-resource knowledge graph.

  Lifecycle: `:pending` -> `:processing` -> `:extracted` | `:failed` | `:superseded`

  The `content_fingerprint` (SHA-256 of `raw_text`) lets the extraction
  pipeline detect unchanged content and skip re-extraction.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.SuperBrain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "super_brain_episodes"
    repo Magus.Repo
  end

  actions do
    defaults [:read]

    read :list_pending do
      filter expr(status == :pending)
    end

    create :create do
      primary? true

      accept [
        :resource_type,
        :resource_id,
        :graph_name,
        :raw_text,
        :source_user_id,
        :source_weight,
        :extractor_version,
        :metadata
      ]

      change fn changeset, _ ->
        raw = Ash.Changeset.get_attribute(changeset, :raw_text) || ""
        fingerprint = :crypto.hash(:sha256, raw)
        Ash.Changeset.force_change_attribute(changeset, :content_fingerprint, fingerprint)
      end
    end

    update :mark_processing do
      accept []
      require_atomic? false
      change set_attribute(:status, :processing)
    end

    update :mark_extracted do
      accept [:extraction_model]
      require_atomic? false
      change set_attribute(:status, :extracted)
      change set_attribute(:extracted_at, &DateTime.utc_now/0)
    end

    update :mark_failed do
      accept [:last_error]
      require_atomic? false
      change set_attribute(:status, :failed)
      change atomic_update(:attempt_count, expr(attempt_count + 1))
    end

    update :supersede do
      accept []
      require_atomic? false
      change set_attribute(:status, :superseded)
    end
  end

  policies do
    bypass action_type([:read, :create, :update]) do
      authorize_if Magus.Checks.IsAiAgent
    end

    policy action_type(:read) do
      authorize_if expr(source_user_id == ^actor(:id))
    end

    policy action_type(:create) do
      authorize_if changing_attributes(source_user_id: [to: {:_actor, :id}])
    end

    policy action_type([:update]) do
      authorize_if expr(source_user_id == ^actor(:id))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :resource_type, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :brain_page,
                    :brain_source,
                    :brain_pin,
                    :brain_links,
                    :file_chunk,
                    :memory,
                    :file,
                    :draft,
                    :message
                  ]
    end

    attribute :resource_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :graph_name, :string do
      allow_nil? false
      public? true
    end

    attribute :raw_text, :string do
      # Keep "" as "" instead of the Ash string-type default (`allow_empty?:
      # false`), which casts "" to nil and would trip `allow_nil? false` with
      # an `Ash.Error.Changes.Required`. A resource with no extractable text
      # (an empty draft, a frontmatter-only page) legitimately yields a blank
      # Episode; recording it once stops the backfill re-enqueuing it forever.
      allow_nil? false
      constraints allow_empty?: true
      public? true
    end

    attribute :content_fingerprint, :binary do
      allow_nil? false
      public? true
    end

    attribute :source_weight, :float do
      default 1.0
      allow_nil? false
      public? true
    end

    attribute :extractor_version, :string do
      allow_nil? true
      public? true
    end

    attribute :status, :atom do
      default :pending
      allow_nil? false
      public? true
      constraints one_of: [:pending, :processing, :extracted, :failed, :superseded]
    end

    attribute :attempt_count, :integer do
      default 0
      allow_nil? false
      public? true
    end

    attribute :last_error, :string do
      allow_nil? true
      public? true
    end

    attribute :extraction_model, :string do
      allow_nil? true
      public? true
    end

    attribute :extracted_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :source_user_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :metadata, :map do
      description """
      Replay parameters for episode types whose worker args are not
      derivable from `resource_id`. `:brain_pin` episodes store
      `%{"source_page_id", "target_page_id", "predicate"}` here so
      `mix super_brain.rebuild` can re-dispatch `IngestBrainPin`.
      `:brain_links` episodes store `%{"source_page_id", "target_titles"}`
      for human-readable replay context, but replay by `resource_id`
      (= page id) since `IngestBrainLinks` re-reads `brain_page_links`. Nil
      for ordinary resource_id-replayable episodes (brain_page /
      brain_source, memory, file_chunk, draft).
      """

      allow_nil? true
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :source_user, Magus.Accounts.User do
      source_attribute :source_user_id
      define_attribute? false
      attribute_writable? false
    end
  end

  identities do
    # Append-only provenance trail (closes D7): we deliberately do NOT
    # declare an Ash identity here. The database enforces a partial unique
    # index in `super_brain_episodes_partial_unique.exs`: at most one row
    # with `status = 'extracted'` may exist per `(resource_type,
    # resource_id)`, while arbitrarily many `:superseded` / `:failed` rows
    # may coexist for replay and debugging. Ash does not natively express
    # partial unique constraints, so the constraint lives in raw SQL and
    # the resource layer enforces the append-only flow via the
    # supersede-then-create path in
    # `Magus.SuperBrain.Workers.ExtractBase.claim_episode/2`.
  end
end
