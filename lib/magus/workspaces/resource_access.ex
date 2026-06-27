defmodule Magus.Workspaces.ResourceAccess do
  @moduledoc """
  Generic resource access grants.

  Represents an entry in a polymorphic access-control list: a grant of a role
  (viewer/editor/owner) to a grantee (user/workspace/custom_agent) on a target
  resource (folder/file/conversation/prompt/custom_agent/brain/knowledge_collection).

  The pair (resource_type, resource_id, grantee_type, grantee_id) is unique, so
  a grantee has at most one role on any given resource. Use `:update_role` to
  change an existing grant.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Workspaces,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @resource_types [
    :folder,
    :file,
    :conversation,
    :prompt,
    :custom_agent,
    :brain,
    :knowledge_collection,
    :mcp_server,
    :skill
  ]
  @grantee_types [:user, :workspace, :custom_agent]
  @roles [:viewer, :editor, :owner]

  def resource_types, do: @resource_types
  def grantee_types, do: @grantee_types
  def roles, do: @roles

  postgres do
    table "resource_accesses"
    repo Magus.Repo
  end

  actions do
    defaults [:read]

    create :grant do
      accept [:resource_type, :resource_id, :grantee_type, :grantee_id, :role]

      change set_attribute(:granted_at, &DateTime.utc_now/0)
      change relate_actor(:granted_by, allow_nil?: true)
    end

    update :update_role do
      accept [:role]
    end

    destroy :revoke do
      primary? true
    end

    read :for_resource do
      argument :resource_type, :atom, allow_nil?: false
      argument :resource_id, :uuid, allow_nil?: false

      filter expr(
               resource_type == ^arg(:resource_type) and
                 resource_id == ^arg(:resource_id)
             )
    end

    read :for_grantee do
      argument :grantee_type, :atom, allow_nil?: false
      argument :grantee_id, :uuid, allow_nil?: false

      filter expr(
               grantee_type == ^arg(:grantee_type) and
                 grantee_id == ^arg(:grantee_id)
             )
    end
  end

  policies do
    policy action([:grant, :revoke, :update_role]) do
      authorize_if Magus.Workspaces.Checks.ActorCanGrantResourceAccess
    end

    policy action_type(:read) do
      authorize_if expr(grantee_type == :user and grantee_id == ^actor(:id))
      authorize_if Magus.Workspaces.Checks.ActorCanReadResourceAccess
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :resource_type, :atom do
      allow_nil? false
      constraints one_of: @resource_types
      public? true
    end

    attribute :resource_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :grantee_type, :atom do
      allow_nil? false
      constraints one_of: @grantee_types
      public? true
    end

    attribute :grantee_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :role, :atom do
      allow_nil? false
      constraints one_of: @roles
      public? true
    end

    attribute :granted_by_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :granted_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :granted_by, Magus.Accounts.User do
      source_attribute :granted_by_id
      destination_attribute :id
      attribute_writable? false
      allow_nil? true
      public? true
    end
  end

  identities do
    identity :unique_grant, [:resource_type, :resource_id, :grantee_type, :grantee_id]
  end
end
