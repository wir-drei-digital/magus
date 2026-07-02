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

  require Ash.Query

  postgres do
    table "organization_members"
    repo Magus.Repo

    custom_indexes do
      index [:user_id]
    end

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

      validate {Magus.Organizations.OrganizationMember.Validations.OneOrgPerUser, []}

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :invite_token, generate_token())
      end

      change {Magus.Organizations.OrganizationMember.Changes.FireSeatSync, event: :activated}
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

      validate {Magus.Organizations.OrganizationMember.Validations.OneOrgPerUser, []}

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :invite_token, generate_token())
      end

      change {Magus.Organizations.OrganizationMember.Changes.FireSeatSync, event: :activated}
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

      validate {Magus.Organizations.Organization.Validations.NotArchived, []}

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(:invite_token, generate_token())
        |> Ash.Changeset.force_change_attribute(
          :invite_expires_at,
          DateTime.add(DateTime.utc_now(), 7, :day)
        )
      end

      change Magus.Organizations.OrganizationMember.Changes.SendInviteEmail
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

      change Magus.Organizations.OrganizationMember.Changes.SendInviteEmail
    end

    update :accept do
      accept []
      require_atomic? false
      validate {Magus.Organizations.OrganizationMember.Validations.OneOrgPerUser, []}
      change set_attribute(:status, :active)
      change set_attribute(:joined_at, &DateTime.utc_now/0)
      change relate_actor(:user)
      change {Magus.Organizations.OrganizationMember.Changes.FireSeatSync, event: :activated}
      change {Magus.Organizations.OrganizationMember.Changes.AddToSharedWorkspace, []}
    end

    update :change_role do
      accept []
      require_atomic? false

      argument :role, :atom do
        allow_nil? false
        constraints one_of: [:owner, :member]
      end

      change set_attribute(:role, arg(:role))
      validate {Magus.Organizations.OrganizationMember.Validations.NotLastOwner, []}
    end

    update :set_member_spend_cap do
      description "Owner sets or clears a member's monthly spend cap override (CHF cents)."
      accept [:spend_cap_cents]
      require_atomic? false
    end

    update :remove do
      accept []
      require_atomic? false
      change set_attribute(:status, :removed)
      change set_attribute(:removed_at, &DateTime.utc_now/0)
      validate {Magus.Organizations.OrganizationMember.Validations.NotLastOwner, []}
      change {Magus.Organizations.OrganizationMember.Changes.FireSeatSync, event: :removed}
    end

    update :remove_for_archive do
      description "Internal: offboard a member during org archive. No seat-sync, no last-owner guard."
      accept []
      require_atomic? false
      change set_attribute(:status, :removed)
      change set_attribute(:removed_at, &DateTime.utc_now/0)
    end

    update :leave_org do
      description "A member removes their own active membership (revert-to-personal)."
      accept []
      require_atomic? false
      change set_attribute(:status, :removed)
      change set_attribute(:removed_at, &DateTime.utc_now/0)
      validate {Magus.Organizations.OrganizationMember.Validations.NotLastOwner, []}
      change {Magus.Organizations.OrganizationMember.Changes.FireSeatSync, event: :removed}
    end

    update :transfer_ownership do
      accept []
      require_atomic? false
      transaction? true
      description "Promotes this member to :owner and demotes the acting owner to :member."

      validate {Magus.Organizations.OrganizationMember.Validations.ValidTransferTarget, []}

      change fn changeset, context ->
        Ash.Changeset.after_action(changeset, fn _cs, target ->
          actor = context.actor

          # Demote the acting owner
          Magus.Organizations.OrganizationMember
          |> Ash.Query.filter(
            organization_id == ^target.organization_id and
              user_id == ^actor.id and
              role == :owner and
              status == :active
          )
          |> Ash.read!(authorize?: false)
          |> Enum.each(fn m ->
            m
            |> Ash.Changeset.for_update(:change_role, %{role: :member}, authorize?: false)
            |> Ash.update!()
          end)

          # Point the org's denormalized owner_id at the new owner
          Magus.Organizations.Organization
          |> Ash.get!(target.organization_id, authorize?: false)
          |> Ash.Changeset.for_update(:update_owner, %{owner_id: target.user_id},
            authorize?: false
          )
          |> Ash.update!()

          Magus.Organizations.SeatSync.on_ownership_transferred(target.organization_id)

          {:ok, %{target | role: :owner}}
        end)
      end

      change set_attribute(:role, :owner)
    end

    read :by_organization do
      argument :organization_id, :uuid, allow_nil?: false
      filter expr(organization_id == ^arg(:organization_id))
    end

    read :active_with_user_by_organization do
      argument :organization_id, :uuid, allow_nil?: false

      filter expr(
               organization_id == ^arg(:organization_id) and status == :active and
                 not is_nil(user_id)
             )
    end

    read :by_invite_token do
      argument :invite_token, :string, allow_nil?: false
      get? true
      filter expr(invite_token == ^arg(:invite_token) and status == :invited)
    end

    read :my_active_membership do
      description "The current actor's active membership (with its organization)."
      filter expr(status == :active and user_id == ^actor(:id))
      prepare build(load: [:organization])
    end
  end

  policies do
    policy action([:create_owner, :create_member]) do
      authorize_if always()
    end

    policy action([
             :invite,
             :resend_invite,
             :change_role,
             :remove,
             :transfer_ownership,
             :set_member_spend_cap
           ]) do
      authorize_if {Magus.Organizations.OrganizationMember.Checks.ActorIsOrgOwner, []}
    end

    policy action(:accept) do
      authorize_if actor_present()
    end

    # Internal offboarding during org archive. Human actors never match; the
    # ArchiveOrganization change calls it with authorize?: false.
    policy action(:remove_for_archive) do
      authorize_if Magus.Organizations.Checks.ActorIsSystem
    end

    policy action(:leave_org) do
      authorize_if expr(user_id == ^actor(:id))
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
