defmodule Magus.Brain.PageSource do
  @moduledoc """
  Derived join: which `Magus.Brain.Source` rows are referenced from each
  page body. Populated from ```source fences in the body. Read-only from
  application code outside the rebuild pipeline.

  `position` captures the order the source fences appear in the body so
  the UI can present them in document order without re-parsing the body.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Brain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "brain_page_sources"
    repo Magus.Repo

    references do
      reference :page, on_delete: :delete
      reference :source, on_delete: :delete
    end
  end

  typescript do
    type_name "BrainPageSource"
  end

  actions do
    defaults [:read, :destroy]

    read :for_page do
      argument :page_id, :uuid, allow_nil?: false
      filter expr(page_id == ^arg(:page_id))
      prepare build(sort: [position: :asc])
    end

    read :for_source do
      argument :source_id, :uuid, allow_nil?: false
      filter expr(source_id == ^arg(:source_id))
    end

    create :create do
      accept [:page_id, :source_id, :position]
    end
  end

  policies do
    bypass action_type(:read) do
      authorize_if Magus.Checks.IsAiAgent
    end

    policy action_type(:read) do
      authorize_if {Magus.Brain.Checks.BrainAccessFilter, path: :via_page, min_role: :viewer}
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

    attribute :position, :integer, allow_nil?: false, default: 0, public?: true

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :page, Magus.Brain.Page, allow_nil?: false
    belongs_to :source, Magus.Brain.Source, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_page_source, [:page_id, :source_id]
  end
end
