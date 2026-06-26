defmodule Magus.Workspaces.WorkspaceMember do
  @moduledoc """
  Represents a user's membership in a workspace.

  Roles:
  - :admin - Full control (invite/deactivate members, manage workspace)
  - :member - Standard access

  Statuses:
  - :invited - Invited but not yet accepted
  - :active - Active member
  - :deactivated - Deactivated (soft-removed)
  """
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Workspaces,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshTypescript.Resource]

  postgres do
    table "workspace_members"
    repo Magus.Repo

    identity_wheres_to_sql unique_membership: "user_id IS NOT NULL",
                           unique_invite: "status != 'deactivated'"
  end

  paper_trail do
    primary_key_type :uuid_v7
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_attributes [:inserted_at, :updated_at, :invite_token]
    belongs_to_actor :user, Magus.Accounts.User, domain: Magus.Accounts
  end

  typescript do
    type_name "WorkspaceMember"
  end

  actions do
    defaults [:read]

    create :create_admin do
      accept []
      argument :workspace_id, :uuid, allow_nil?: false
      argument :user_id, :uuid, allow_nil?: false
      argument :invite_email, :string, allow_nil?: false

      change set_attribute(:workspace_id, arg(:workspace_id))
      change set_attribute(:user_id, arg(:user_id))
      change set_attribute(:invite_email, arg(:invite_email))
      change set_attribute(:role, :admin)
      change set_attribute(:status, :active)
      change set_attribute(:is_active, true)
      change set_attribute(:invited_at, &DateTime.utc_now/0)
      change set_attribute(:joined_at, &DateTime.utc_now/0)

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :invite_token, generate_token())
      end
    end

    create :create_member do
      accept []
      argument :workspace_id, :uuid, allow_nil?: false
      argument :user_id, :uuid, allow_nil?: false
      argument :invite_email, :string, allow_nil?: false

      change set_attribute(:workspace_id, arg(:workspace_id))
      change set_attribute(:user_id, arg(:user_id))
      change set_attribute(:invite_email, arg(:invite_email))
      change set_attribute(:role, :member)
      change set_attribute(:status, :active)
      change set_attribute(:is_active, true)
      change set_attribute(:invited_at, &DateTime.utc_now/0)
      change set_attribute(:joined_at, &DateTime.utc_now/0)

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :invite_token, generate_token())
      end
    end

    create :invite do
      accept []
      argument :workspace_id, :uuid, allow_nil?: false
      argument :invite_email, :string, allow_nil?: false

      change set_attribute(:workspace_id, arg(:workspace_id))
      change set_attribute(:invite_email, arg(:invite_email))
      change set_attribute(:role, :member)
      change set_attribute(:status, :invited)
      change set_attribute(:is_active, false)
      change set_attribute(:invited_at, &DateTime.utc_now/0)

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(:invite_token, generate_token())
        |> Ash.Changeset.force_change_attribute(
          :invite_expires_at,
          DateTime.add(DateTime.utc_now(), 7, :day)
        )
      end

      change Magus.Workspaces.WorkspaceMember.Changes.SendInviteEmail

      # Emit notification when user_id is already known at invite time.
      # For unregistered invitees (user_id is nil), this is a no-op; they rely on email.
      change {Magus.Workspaces.WorkspaceMember.Changes.EmitMembershipNotification,
              kind: :workspace_invite}
    end

    update :resend_invite do
      accept []
      require_atomic? false
      description "Regenerate invite_token, reset expiry, re-send invite email"

      validate attribute_equals(:status, :invited)

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(:invite_token, generate_token())
        |> Ash.Changeset.force_change_attribute(
          :invite_expires_at,
          DateTime.add(DateTime.utc_now(), 7, :day)
        )
      end

      change Magus.Workspaces.WorkspaceMember.Changes.SendInviteEmail
    end

    update :accept do
      accept []
      require_atomic? false
      change set_attribute(:status, :active)
      change set_attribute(:is_active, true)
      change set_attribute(:joined_at, &DateTime.utc_now/0)
      change relate_actor(:user)
    end

    update :change_role do
      accept []
      require_atomic? false

      argument :role, :atom do
        allow_nil? false
        constraints one_of: [:admin, :member]
      end

      change set_attribute(:role, arg(:role))

      validate {Magus.Workspaces.WorkspaceMember.Validations.NotLastAdmin, []}

      change {Magus.Workspaces.WorkspaceMember.Changes.EmitMembershipNotification,
              kind: :workspace_role_changed}
    end

    update :deactivate do
      accept []
      require_atomic? false

      argument :for_workspace_removal, :boolean do
        allow_nil? false
        default false
        description "When true, skips the last-admin check (workspace itself is being removed)"
      end

      change set_attribute(:status, :deactivated)
      change set_attribute(:is_active, false)
      change set_attribute(:deactivated_at, &DateTime.utc_now/0)

      validate {Magus.Workspaces.WorkspaceMember.Validations.NotLastAdmin, []},
        where: [argument_equals(:for_workspace_removal, false)]

      change {Magus.Workspaces.WorkspaceMember.Changes.EmitMembershipNotification,
              kind: :workspace_removed}
    end

    update :transfer_ownership do
      accept []
      require_atomic? false
      transaction? true
      description "Promotes this member to :admin and demotes the acting admin to :member"

      change Magus.Workspaces.WorkspaceMember.Changes.TransferOwnership
    end

    read :by_workspace do
      argument :workspace_id, :uuid, allow_nil?: false
      filter expr(workspace_id == ^arg(:workspace_id))
    end

    read :by_invite_token do
      argument :invite_token, :string, allow_nil?: false
      get? true

      filter expr(invite_token == ^arg(:invite_token) and status == :invited)
    end
  end

  policies do
    policy action([:create_admin, :create_member]) do
      authorize_if always()
    end

    policy action(:invite) do
      authorize_if {Magus.Workspaces.WorkspaceMember.Checks.ActorIsWorkspaceAdmin, []}
    end

    policy action(:resend_invite) do
      authorize_if {Magus.Workspaces.WorkspaceMember.Checks.ActorIsWorkspaceAdmin, []}
    end

    policy action(:change_role) do
      authorize_if expr(
                     exists(
                       workspace.members,
                       is_active == true and role == :admin and user_id == ^actor(:id)
                     )
                   )
    end

    policy action(:deactivate) do
      authorize_if expr(
                     exists(
                       workspace.members,
                       is_active == true and role == :admin and user_id == ^actor(:id)
                     )
                   )
    end

    policy action(:transfer_ownership) do
      authorize_if expr(
                     exists(
                       workspace.members,
                       is_active == true and role == :admin and user_id == ^actor(:id)
                     )
                   )
    end

    policy action(:accept) do
      authorize_if actor_present()
    end

    policy action_type(:read) do
      authorize_if expr(
                     exists(
                       workspace.members,
                       is_active == true and user_id == ^actor(:id)
                     )
                   )
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :role, :atom do
      allow_nil? false
      default :member
      constraints one_of: [:admin, :member]
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :invited
      constraints one_of: [:invited, :active, :deactivated]
      public? true
    end

    attribute :is_active, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :invited_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :joined_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :deactivated_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :invite_token, :string do
      allow_nil? true
      public? false
    end

    attribute :invite_expires_at, :utc_datetime_usec do
      allow_nil? true
      public? false
    end

    attribute :invite_email, :string do
      allow_nil? true
      # Public so the workspace members UI can show pending-invite emails.
      # Reads are still gated to active workspace members by policy; the
      # secret invite_token stays public? false.
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :workspace, Magus.Workspaces.Workspace do
      allow_nil? false
      public? true
    end

    belongs_to :user, Magus.Accounts.User do
      allow_nil? true
      public? true
    end
  end

  identities do
    identity :unique_membership, [:workspace_id, :user_id], where: expr(not is_nil(user_id))

    identity :unique_invite, [:workspace_id, :invite_email], where: expr(status != :deactivated)
    identity :unique_token, [:invite_token]
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
