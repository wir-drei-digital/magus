defmodule Magus.Test.FixtureDomain do
  @moduledoc """
  In-memory Ash domain used to host `Magus.Test.WorkspaceScopedFixture`
  for exercising `Magus.Workspaces.Policies.workspace_scoped_policies/1`.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource Magus.Test.WorkspaceScopedFixture
  end
end

defmodule Magus.Test.WorkspaceScopedFixture do
  @moduledoc """
  Minimal fixture resource used to test `workspace_scoped_policies/1`.

  Exercises the shared policy macro without touching real application
  resources. Backed by Postgres (same data layer as
  `Magus.Workspaces.ResourceAccess`) so the `AccessCheck` filter's
  `exists/2` subquery against `resource_accesses` can be compiled.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Test.FixtureDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "workspace_scoped_fixtures"
    repo Magus.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:name, :workspace_id]
      change relate_actor(:user)
    end

    update :update do
      primary? true
      accept [:name]
    end
  end

  policies do
    import Magus.Workspaces.Policies
    workspace_scoped_policies(resource_type: :folder)
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    timestamps()
  end

  relationships do
    belongs_to :user, Magus.Accounts.User do
      allow_nil? false
      public? true
    end

    belongs_to :workspace, Magus.Workspaces.Workspace do
      allow_nil? true
      public? true
    end
  end
end
