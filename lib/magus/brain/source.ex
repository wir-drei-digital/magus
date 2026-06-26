defmodule Magus.Brain.Source do
  @moduledoc """
  A first-class source (URL + ingested content) referenced from page
  bodies via fenced ```source blocks.

  Keyed by `(brain_id, url)` so the same URL referenced from multiple
  pages within a brain reuses the same row. Ingestion is decoupled from
  the page save (`ingest_status` state machine + the future
  `Magus.Brain.Source.IngestWorker`).

  Phase A only defines schema + minimal actions. The ingest worker,
  chunker, and the after-action hook on `Page.update_body` that upserts
  sources from `source` fences arrive in Phase B/C.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Brain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "brain_sources"
    repo Magus.Repo

    references do
      reference :brain, on_delete: :delete
    end
  end

  typescript do
    type_name "BrainSource"
  end

  actions do
    defaults [:read, :destroy]

    read :for_brain do
      argument :brain_id, :uuid, allow_nil?: false
      filter expr(brain_id == ^arg(:brain_id))
      prepare build(sort: [inserted_at: :desc])
    end

    read :by_url do
      argument :brain_id, :uuid, allow_nil?: false
      argument :url, :string, allow_nil?: false
      filter expr(brain_id == ^arg(:brain_id) and url == ^arg(:url))
    end

    create :create do
      primary? true

      accept [
        :brain_id,
        :url,
        :title,
        :description,
        :source_type,
        :author
      ]

      change Magus.Brain.Source.Changes.EnqueueIngestWorker
    end

    create :from_legacy_block do
      description """
      Used by `Magus.Brain.Migrations.BackfillSources` to seed a Source row
      from an existing `:source` block plus its derived ingest state. Accepts
      every ingest-related attribute so the worker can preserve whatever
      `metadata["ingested"]` / `metadata["ingestion_error"]` recorded on the
      legacy block, plus any aggregated child-paragraph text as
      `ingested_content`. NOT for user-facing or agent-facing calls — the
      `forbid_if always()` write policy blocks anything but `authorize?: false`.

      `EnqueueIngestWorker` runs as the after-action; rows that arrive
      already `:ingested` or `:failed` are no-ops, but a legacy block that
      never finished ingesting (status `:pending`) gets a fresh worker.
      """

      accept [
        :brain_id,
        :url,
        :title,
        :description,
        :source_type,
        :author,
        :ingest_status,
        :ingest_error,
        :ingested_at,
        :ingested_content
      ]

      change Magus.Brain.Source.Changes.EnqueueIngestWorker
    end

    update :update do
      primary? true
      accept [:title, :description, :source_type, :author]
    end

    update :ingest do
      description """
      Records the result of fetching/extracting content from `url`.

      Called by `Magus.Brain.Source.IngestWorker`. Accepts `:title` so the
      worker can override an empty user-supplied title with the page title
      pulled from the HTML response. Mutations to `:ingest_status`,
      `:ingest_error`, `:ingested_content`, and `:ingested_at` move the
      ingest state machine forward.
      """

      accept [:ingested_content, :ingest_status, :ingest_error, :ingested_at, :title]
      require_atomic? false

      change Magus.Brain.Source.Changes.EnqueueSuperBrainExtraction
    end
  end

  policies do
    bypass action_type(:read) do
      authorize_if Magus.Checks.IsAiAgent
    end

    policy action_type(:read) do
      authorize_if {Magus.Brain.Checks.BrainAccessFilter, path: :direct, min_role: :viewer}
    end

    # Writes (including the `:destroy` default) are mediated by Phase C's
    # after-action pipeline and the ingest worker, both of which use
    # `authorize?: false`. The destroy action is kept in defaults so cascade
    # cleanup paths can call it; the unconditional forbid is intentional
    # for any caller passing an `actor:` so accidental user-facing writes
    # fail loud.
    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :url, :string, allow_nil?: false, public?: true
    attribute :title, :string, public?: true
    attribute :description, :string, public?: true
    attribute :author, :string, public?: true

    # Includes the legacy source-block values (`web`, `paper`, `book`, `video`)
    # so backfill from `Magus.Brain.Block` `:source` rows is lossless, plus
    # the new types we expect to ingest going forward (`pdf`, `feed`, `other`).
    attribute :source_type, :atom,
      constraints: [one_of: [:web, :paper, :book, :video, :pdf, :feed, :other]],
      default: :web,
      public?: true

    attribute :ingest_status, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :ingesting, :ingested, :failed]],
      public?: true

    attribute :ingested_content, :string
    attribute :ingest_error, :string
    attribute :ingested_at, :utc_datetime_usec

    timestamps()
  end

  relationships do
    belongs_to :brain, Magus.Brain.BrainResource, allow_nil?: false
  end

  identities do
    identity :unique_brain_url, [:brain_id, :url]
  end
end
