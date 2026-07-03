defmodule Magus.Library.Tag do
  @moduledoc """
  Tag resource for categorizing prompts.

  Tags are scoped: a tag belongs either to a user (personal, visible only to
  its owner), to a workspace (shared with all active members), or to neither
  (legacy/global tags from the public library, readable by everyone).
  """
  use Ash.Resource,
    domain: Magus.Library,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "tags"
    repo Magus.Repo

    references do
      reference :user, on_delete: :delete, index?: true
      reference :workspace, on_delete: :delete, index?: true
    end
  end

  typescript do
    type_name "Tag"
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
    end

    create :create do
      accept [:name]
      argument :workspace_id, :uuid, allow_nil?: true

      change set_attribute(:workspace_id, arg(:workspace_id))
      change Magus.Library.Tag.Changes.ScopeToActor
      validate Magus.Library.Tag.Validations.ActorInWorkspace
    end

    create :get_or_create do
      accept [:name]
      argument :workspace_id, :uuid, allow_nil?: true
      upsert? true
      upsert_identity :unique_name_per_scope

      change set_attribute(:workspace_id, arg(:workspace_id))
      change Magus.Library.Tag.Changes.ScopeToActor
      validate Magus.Library.Tag.Validations.ActorInWorkspace
    end
  end

  policies do
    # Legacy/global tags (no owner, no workspace) stay readable by everyone —
    # they label public-library prompts.
    policy action_type(:read) do
      authorize_if expr(is_nil(user_id) and is_nil(workspace_id))
      authorize_if expr(user_id == ^actor(:id))
      authorize_if expr(exists(workspace.members, user_id == ^actor(:id) and is_active == true))
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type(:destroy) do
      authorize_if expr(user_id == ^actor(:id))

      authorize_if expr(
                     exists(
                       workspace.members,
                       user_id == ^actor(:id) and is_active == true and role == :admin
                     )
                   )
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :ci_string do
      allow_nil? false
      description "The tag name (case-insensitive)"
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Magus.Accounts.User do
      description "Owner of a personal tag; nil for workspace and legacy/global tags"
      public? true
    end

    belongs_to :workspace, Magus.Workspaces.Workspace do
      description "Workspace a shared tag belongs to; nil for personal and legacy/global tags"
      public? true
    end

    has_many :prompt_tags, Magus.Library.PromptTag

    many_to_many :prompts, Magus.Library.Prompt do
      through Magus.Library.PromptTag
      source_attribute_on_join_resource :tag_id
      destination_attribute_on_join_resource :prompt_id
    end
  end

  identities do
    # nils_distinct?: false so the name is unique per user, per workspace, and
    # globally for legacy rows (NULLS NOT DISTINCT unique index).
    identity :unique_name_per_scope, [:name, :user_id, :workspace_id], nils_distinct?: false
  end
end
