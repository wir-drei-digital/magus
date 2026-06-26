defmodule Magus.Models.RoleAssignment do
  @moduledoc """
  Admin assignment of a model to an internal model role (see
  `Magus.Models.Roles`). One row per role (upsert on role).

  `disabled?: true` switches a nilable role's feature off; for non-nilable
  roles resolution skips a disabled assignment and continues down the chain.
  Absence of a row means "use config/default resolution".
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Models,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "model_role_assignments"
    repo Magus.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :assign do
      primary? true
      accept [:role, :model_id, :disabled?]
      upsert? true
      upsert_identity :unique_role
      upsert_fields [:model_id, :disabled?]
    end

    read :by_role do
      argument :role, :string, allow_nil?: false
      filter expr(role == ^arg(:role))
      get? true
    end
  end

  policies do
    # Resolution runs actorless from internal call sites.
    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if Magus.Checks.IsAdmin
    end
  end

  validations do
    validate {Magus.Models.RoleAssignment.Validations.KnownRole, []}
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :string, allow_nil?: false, public?: true

    attribute :disabled?, :boolean do
      default false
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :model, Magus.Chat.Model do
      attribute_writable? true
      public? true
    end
  end

  identities do
    identity :unique_role, [:role]
  end
end
