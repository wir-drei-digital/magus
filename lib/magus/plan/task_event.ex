defmodule Magus.Plan.TaskEvent do
  @moduledoc """
  Append-only coordination/audit trail for plan tasks. Backs the per-task
  history and (in Plan 3) the brain overview's recent-activity feed. Current
  task rows remain the source of truth; this is not event sourcing.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Plan,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "plan_task_events"
    repo Magus.Repo

    references do
      reference :task, on_delete: :delete
    end
  end

  typescript do
    type_name "TaskEvent"
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:task_id, :brain_page_id, :kind, :actor_label, :metadata]
    end

    read :for_plan do
      argument :brain_page_id, :uuid, allow_nil?: false
      filter expr(brain_page_id == ^arg(:brain_page_id))
      prepare build(sort: [inserted_at: :desc])
    end

    read :for_brain do
      description "Recent task activity across every plan page in a brain."
      argument :brain_id, :uuid, allow_nil?: false
      filter expr(task.brain_page.brain_id == ^arg(:brain_id))
      prepare build(sort: [inserted_at: :desc], limit: 50)
    end
  end

  policies do
    # Reads only: an AI actor must NOT be able to bypass the create lock below.
    bypass action_type([:read]) do
      authorize_if Magus.Checks.IsAiAgent
    end

    policy action(:for_plan) do
      # Strict so a non-member is FORBIDDEN (error) rather than silently filtered
      # to an empty list: matches Task `:for_plan`/`:for_brain`. Safe here because
      # `:for_plan` is read directly (domain interface + `plan_task_events` RPC),
      # never as a relationship aggregate. ActorCanAccessTaskPage is a simple check.
      access_type :strict
      authorize_if {Magus.Plan.Checks.ActorCanAccessTaskPage, min_role: :viewer}
    end

    # `:for_brain` is read two ways:
    #   * internally by `Magus.Plan.brain_task_overview/2` with `authorize?: false`
    #     (bypasses policies), AFTER the Task `:for_brain` read has authorized
    #     brain access, and
    #   * over RPC (`brain_task_events`) for the SPA brain-overview activity feed.
    # A FILTER check (not the simple ActorCanAccessTaskPage) is required so it
    # authorizes correctly under RPC's non-strict auth: it restricts rows to the
    # actor's accessible brains via `exists(task.brain_page, brain_id in ^ids)`
    # rather than silently returning `[]` for everyone. Same path TaskDependency
    # reads use.
    policy action(:for_brain) do
      authorize_if {Magus.Brain.Checks.BrainAccessFilter,
                    path: :via_task_brain_page, min_role: :viewer}
    end

    policy action_type(:create) do
      # Created only internally (authorize?: false) by RecordTaskEvent.
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :brain_page_id, :uuid, allow_nil?: false, public?: true

    attribute :kind, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :created,
                    :claimed,
                    :released,
                    :status_changed,
                    :completed,
                    :reassigned,
                    :lease_expired
                  ]
    end

    attribute :actor_label, :string, allow_nil?: true, public?: true
    attribute :metadata, :map, default: %{}, public?: true

    # Public so the brain overview activity feed can select + display relative time.
    create_timestamp :inserted_at, public?: true
  end

  relationships do
    belongs_to :task, Magus.Plan.Task do
      allow_nil? false
      public? true
    end
  end
end
