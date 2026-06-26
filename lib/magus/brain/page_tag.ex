defmodule Magus.Brain.PageTag do
  @moduledoc """
  Derived tag index: every `tag` discovered in a page body via either the
  `tags:` frontmatter list or inline `#tag` syntax.

  `brain_id` is denormalized off `Page.brain_id` so listing all tags in a
  brain doesn't need to join through `brain_pages`. `source` records where
  the tag came from (`:frontmatter | :inline`) — when both sources mention
  the same tag, the frontmatter row wins (rebuild dedupes).
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Brain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "brain_page_tags"
    repo Magus.Repo

    references do
      reference :page, on_delete: :delete
      reference :brain, on_delete: :delete
    end

    custom_indexes do
      index [:brain_id, :tag], name: "brain_page_tags_brain_id_tag_index"
    end
  end

  actions do
    defaults [:read, :destroy]

    read :for_page do
      argument :page_id, :uuid, allow_nil?: false
      filter expr(page_id == ^arg(:page_id))
      prepare build(sort: [tag: :asc])
    end

    read :for_brain do
      description "All tag rows in the given brain (use list_tags for a deduped tag-count view)."
      argument :brain_id, :uuid, allow_nil?: false
      filter expr(brain_id == ^arg(:brain_id))
      prepare build(sort: [tag: :asc])
    end

    read :pages_with_tag do
      argument :brain_id, :uuid, allow_nil?: false
      argument :tag, :string, allow_nil?: false
      filter expr(brain_id == ^arg(:brain_id) and tag == ^arg(:tag))
    end

    create :create do
      accept [:page_id, :brain_id, :tag, :source]
    end
  end

  policies do
    bypass action_type(:read) do
      authorize_if Magus.Checks.IsAiAgent
    end

    policy action_type(:read) do
      authorize_if {Magus.Brain.Checks.BrainAccessFilter, path: :direct, min_role: :viewer}
    end

    # Writes (including the `:destroy` default) only happen via the Phase
    # B/C rebuild pipeline with `authorize?: false`. Destroy is kept so
    # cascade cleanup paths can call it; user-facing writes fail loud.
    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tag, :string, allow_nil?: false

    attribute :source, :atom,
      allow_nil?: false,
      constraints: [one_of: [:frontmatter, :inline]]

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :page, Magus.Brain.Page, allow_nil?: false
    belongs_to :brain, Magus.Brain.BrainResource, allow_nil?: false
  end

  identities do
    identity :unique_page_tag, [:page_id, :tag]
  end
end
