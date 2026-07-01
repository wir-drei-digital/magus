defmodule Magus.Organizations.OrganizationMember do
  @moduledoc """
  A user's membership in an organization.

  Roles: :owner (billing + full control), :member (uses their seat).
  Statuses: :invited (pending), :active, :removed (offboarded).
  """
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Organizations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshTypescript.Resource]

  postgres do
    table "organization_members"
    repo Magus.Repo

    identity_wheres_to_sql unique_membership: "user_id IS NOT NULL",
                           unique_invite: "status != 'removed'"
  end

  paper_trail do
    primary_key_type :uuid_v7
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_attributes [:inserted_at, :updated_at, :invite_token]
    belongs_to_actor :user, Magus.Accounts.User, domain: Magus.Accounts
  end

  typescript do
    type_name "OrganizationMember"
  end

  actions do
    defaults [:read]

    create :create_owner do
      accept []
      argument :organization_id, :uuid, allow_nil?: false
      argument :user_id, :uuid, allow_nil?: false
      argument :invite_email, :string, allow_nil?: false

      change set_attribute(:organization_id, arg(:organization_id))
      change set_attribute(:user_id, arg(:user_id))
      change set_attribute(:invite_email, arg(:invite_email))
      change set_attribute(:role, :owner)
      change set_attribute(:status, :active)
      change set_attribute(:invited_at, &DateTime.utc_now/0)
      change set_attribute(:joined_at, &DateTime.utc_now/0)

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :invite_token, generate_token())
      end
    end

    create :create_member do
      accept []
      argument :organization_id, :uuid, allow_nil?: false
      argument :user_id, :uuid, allow_nil?: false
      argument :invite_email, :string, allow_nil?: false

      change set_attribute(:organization_id, arg(:organization_id))
      change set_attribute(:user_id, arg(:user_id))
      change set_attribute(:invite_email, arg(:invite_email))
      change set_attribute(:role, :member)
      change set_attribute(:status, :active)
      change set_attribute(:invited_at, &DateTime.utc_now/0)
      change set_attribute(:joined_at, &DateTime.utc_now/0)

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :invite_token, generate_token())
      end
    end

    create :invite do
      accept []
      argument :organization_id, :uuid, allow_nil?: false
      argument :invite_email, :string, allow_nil?: false

      change set_attribute(:organization_id, arg(:organization_id))
      change set_attribute(:invite_email, arg(:invite_email))
      change set_attribute(:role, :member)
      change set_attribute(:status, :invited)
      change set_attribute(:invited_at, &DateTime.utc_now/0)

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(:invite_token, generate_token())
        |> Ash.Changeset.force_change_attribute(
          :invite_expires_at,
          DateTime.add(DateTime.utc_now(), 7, :day)
        )
      end
    end

    update :accept do
      accept []
      require_atomic? false
      change set_attribute(:status, :active)
      change set_attribute(:joined_at, &DateTime.utc_now/0)
      change relate_actor(:user)
    end

    read :by_organization do
      argument :organization_id, :uuid, allow_nil?: false
      filter expr(organization_id == ^arg(:organization_id))
    end

    read :by_invite_token do
      argument :invite_token, :string, allow_nil?: false
      get? true
      filter expr(invite_token == ^arg(:invite_token) and status == :invited)
    end
  end

  policies do
    policy action([:create_owner, :create_member]) do
      authorize_if always()
    end

    policy action(:invite) do
      authorize_if expr(organization.owner_id == ^actor(:id))
    end

    policy action(:accept) do
      authorize_if actor_present()
    end

    policy action_type(:read) do
      authorize_if expr(
                     exists(
                       organization.members,
                       status == :active and user_id == ^actor(:id)
                     )
                   )
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :role, :atom do
      allow_nil? false
      default :member
      constraints one_of: [:owner, :member]
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :invited
      constraints one_of: [:invited, :active, :removed]
      public? true
    end

    attribute :spend_cap_cents, :integer do
      allow_nil? true
      public? true
      description "Per-member monthly spend cap override (CHF cents). Nil = use plan default."
    end

    attribute :invited_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :joined_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :removed_at, :utc_datetime_usec, allow_nil?: true, public?: true

    attribute :invite_token, :string, allow_nil?: true, public?: false
    attribute :invite_expires_at, :utc_datetime_usec, allow_nil?: true, public?: false

    attribute :invite_email, :string do
      allow_nil? true
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :organization, Magus.Organizations.Organization do
      allow_nil? false
      public? true
    end

    belongs_to :user, Magus.Accounts.User do
      allow_nil? true
      public? true
    end
  end

  identities do
    identity :unique_membership, [:organization_id, :user_id], where: expr(not is_nil(user_id))
    identity :unique_invite, [:organization_id, :invite_email], where: expr(status != :removed)
    identity :unique_token, [:invite_token]
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
