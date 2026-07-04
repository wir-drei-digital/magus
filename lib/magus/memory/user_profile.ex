defmodule Magus.Memory.UserProfile do
  @moduledoc """
  Singleton distilled profile document per (user, workspace bucket).

  Hermes-style working memory: ONE living document per bucket, rewritten in
  place by DistillUserProfile, never appended to. The episodic Memory rows
  remain the source layer; this is the distilled layer injected into every
  conversation. workspace_id nil is the personal bucket (nils_distinct?: false
  on the identity makes it a real singleton).
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Memory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "user_profiles"
    repo Magus.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      argument :user_id, :uuid, allow_nil?: false
      argument :workspace_id, :uuid, allow_nil?: true
      accept [:document]

      change set_attribute(:user_id, arg(:user_id))
      change set_attribute(:workspace_id, arg(:workspace_id))
      validate Magus.Memory.UserProfile.Validations.DocumentSize
    end

    read :for_bucket do
      get? true
      argument :user_id, :uuid, allow_nil?: false
      argument :workspace_id, :uuid, allow_nil?: true

      prepare fn query, _context ->
        require Ash.Query

        user_id = Ash.Query.get_argument(query, :user_id)
        workspace_id = Ash.Query.get_argument(query, :workspace_id)

        query = Ash.Query.filter(query, user_id == ^user_id)

        if is_nil(workspace_id) do
          Ash.Query.filter(query, is_nil(workspace_id))
        else
          Ash.Query.filter(query, workspace_id == ^workspace_id)
        end
      end
    end

    update :set_document do
      accept [:document]
      require_atomic? false

      validate Magus.Memory.UserProfile.Validations.DocumentSize

      change fn changeset, _context ->
        document = Ash.Changeset.get_attribute(changeset, :document) || ""

        changeset
        |> Ash.Changeset.force_change_attribute(:token_estimate, div(String.length(document), 4))
        |> Ash.Changeset.force_change_attribute(:last_distilled_at, DateTime.utc_now())
        |> Ash.Changeset.force_change_attribute(:pending_notes, [])
      end

      change Magus.Memory.UserProfile.Changes.CreateVersion
    end

    update :add_note do
      argument :note, :string, allow_nil?: false
      require_atomic? false

      change fn changeset, _context ->
        note = Ash.Changeset.get_argument(changeset, :note)
        notes = (changeset.data.pending_notes ++ [note]) |> Enum.take(-20)
        Ash.Changeset.force_change_attribute(changeset, :pending_notes, notes)
      end
    end
  end

  policies do
    bypass action_type([:read, :create, :update, :destroy]) do
      authorize_if Magus.Checks.IsAiAgent
    end

    policy action_type(:create) do
      authorize_if Magus.Memory.Memory.Checks.UserIdMatchesActor
    end

    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action_type([:update, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :document, :string,
      allow_nil?: false,
      default: "",
      constraints: [allow_empty?: true, trim?: false]

    attribute :pending_notes, {:array, :string}, allow_nil?: false, default: []
    attribute :token_estimate, :integer, allow_nil?: false, default: 0
    attribute :last_distilled_at, :utc_datetime_usec

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Magus.Accounts.User, allow_nil?: false
    belongs_to :workspace, Magus.Workspaces.Workspace, allow_nil?: true

    has_many :versions, Magus.Memory.UserProfileVersion do
      destination_attribute :user_profile_id
    end
  end

  identities do
    identity :unique_bucket, [:user_id, :workspace_id], nils_distinct?: false
  end
end
