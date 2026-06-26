defmodule Magus.Brain.PageLink do
  @moduledoc """
  Derived index of `[[Page Name]]` wikilinks discovered in page bodies.

  Rebuilt by the Phase B/C `Page.update_body` after-action and the
  initial backfill worker. Read-only from application code outside the
  rebuild pipeline.

  `target_title_at_link_time` is captured at parse time so the UI can
  detect rename drift between the link text in the source body and the
  target page's current title (we don't auto-rewrite bodies on rename).
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Brain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "brain_page_links"
    repo Magus.Repo

    references do
      reference :source_page, on_delete: :delete
      reference :target_page, on_delete: :delete
    end

    custom_indexes do
      index [:target_page_id], name: "brain_page_links_target_page_id_index"
    end
  end

  typescript do
    type_name "BrainPageLink"
  end

  actions do
    defaults [:read, :destroy]

    read :backlinks_for do
      description "All links whose target is the given page (i.e. pages that mention it)."
      argument :page_id, :uuid, allow_nil?: false
      filter expr(target_page_id == ^arg(:page_id))
    end

    read :forward_links_for do
      description "All links whose source is the given page (i.e. pages it mentions)."
      argument :page_id, :uuid, allow_nil?: false
      filter expr(source_page_id == ^arg(:page_id))
    end

    create :create do
      accept [:source_page_id, :target_page_id, :target_title_at_link_time]
    end
  end

  policies do
    bypass action_type(:read) do
      authorize_if Magus.Checks.IsAiAgent
    end

    policy action_type(:read) do
      authorize_if {Magus.Brain.Checks.BrainAccessFilter,
                    path: :via_source_page, min_role: :viewer}
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

    attribute :target_title_at_link_time, :string, allow_nil?: false, public?: true

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :source_page, Magus.Brain.Page, allow_nil?: false, public?: true
    belongs_to :target_page, Magus.Brain.Page, allow_nil?: false
  end

  identities do
    identity :unique_source_target, [:source_page_id, :target_page_id]
  end
end
