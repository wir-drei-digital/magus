defmodule Magus.Brain.Block do
  @moduledoc """
  Read-only view of the legacy `brain_blocks` table, retained so the
  one-shot migration tooling (`mix magus.brain.migrate`, `force_resync`,
  `backfill_audit`) can read existing rows while we backfill them into
  `brain_pages.body`.

  No writes. No paper-trail. No Oban triggers. Once the migration is
  verified complete (`mix magus.brain.backfill_audit` exits 0 across
  all environments) this resource and the underlying table can be
  dropped in the cleanup PRs.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Brain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "brain_blocks"
    repo Magus.Repo

    references do
      reference :page, on_delete: :delete
      reference :parent_block, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :for_page do
      argument :page_id, :uuid, allow_nil?: false
      filter expr(page_id == ^arg(:page_id))
      prepare build(sort: [position: :asc])
    end
  end

  policies do
    policy action([:read, :for_page]) do
      authorize_if {Magus.Brain.Checks.BrainAccessFilter, path: :via_page, min_role: :viewer}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :type, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [
          :paragraph,
          :heading,
          :list_item,
          :code,
          :quote,
          :source,
          :file,
          :message,
          :callout,
          :image,
          :divider,
          :table
        ]
      ]

    attribute :content, :map, default: %{}
    attribute :position, :float, allow_nil?: false
    attribute :depth, :integer, default: 0
    attribute :metadata, :map, default: %{}
    attribute :is_pinned, :boolean, default: false

    attribute :contributor_type, :atom,
      constraints: [one_of: [:user, :custom_agent, :external_agent]]

    attribute :contributor_id, :uuid
    attribute :embedding, Magus.Files.Types.Vector
    attribute :lock_version, :integer, default: 0

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :page, Magus.Brain.Page, allow_nil?: false
    belongs_to :parent_block, __MODULE__
    has_many :children, __MODULE__, destination_attribute: :parent_block_id
  end
end
