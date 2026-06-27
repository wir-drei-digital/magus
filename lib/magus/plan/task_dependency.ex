defmodule Magus.Plan.TaskDependency do
  @moduledoc """
  A directed dependency edge: `task` depends on (is blocked by) `depends_on`.
  Intra-plan and acyclic (enforced by ValidateAcyclic). Authorization rides on
  the dependent task's plan-page access.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Plan,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "plan_task_dependencies"
    repo Magus.Repo

    references do
      reference :task, on_delete: :delete
      reference :depends_on, on_delete: :delete
    end
  end

  typescript do
    type_name "TaskDependency"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept []
      argument :task_id, :uuid, allow_nil?: false
      argument :depends_on_id, :uuid, allow_nil?: false

      change set_attribute(:task_id, arg(:task_id))
      change set_attribute(:depends_on_id, arg(:depends_on_id))
      change Magus.Plan.TaskDependency.Changes.ValidateAcyclic
    end

    read :for_task do
      argument :task_id, :uuid, allow_nil?: false
      filter expr(task_id == ^arg(:task_id))
    end
  end

  policies do
    bypass action_type([:read, :create, :update, :destroy]) do
      authorize_if Magus.Checks.IsAiAgent
    end

    policy action_type([:create]) do
      authorize_if {Magus.Plan.Checks.ActorCanAccessTaskPage, field: :task_id, min_role: :editor}
    end

    # Reads + destroys use a FILTER check (not the simple ActorCanAccessTaskPage)
    # so they authorize correctly in query-based paths: the `dependencies`
    # aggregate/relationship on Task (a SimpleCheck cannot be pushed into the
    # aggregate's SQL and silently filters related rows to zero) and the RPC
    # bulk destroy (which runs over a policy-filtered query, where a SimpleCheck
    # reading changeset data raises "Original data is not available").
    policy action_type([:read, :destroy]) do
      authorize_if {Magus.Brain.Checks.BrainAccessFilter,
                    path: :via_task_brain_page, min_role: :viewer}
    end
  end

  attributes do
    uuid_v7_primary_key :id
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :task, Magus.Plan.Task do
      allow_nil? false
      public? true
    end

    belongs_to :depends_on, Magus.Plan.Task do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_edge, [:task_id, :depends_on_id]
  end
end
