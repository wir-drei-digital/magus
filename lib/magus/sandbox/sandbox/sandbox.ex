defmodule Magus.Sandbox.Sandbox do
  @moduledoc """
  A persistent Python execution environment tied to a conversation.

  ## State Machine

  - `:uninitialized` - Created but no Sprite provisioned yet (lazy provisioning)
  - `:active` - Sprite running, ready to execute code
  - `:suspended` - Checkpointed and paused (cost savings)
  - `:terminated` - Destroyed, no longer usable

  ## Transitions

  - `provision`: uninitialized → active
  - `suspend`: active → suspended
  - `resume`: suspended → active
  - `terminate`: active/suspended → terminated
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Sandbox,
    extensions: [AshStateMachine, AshOban],
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  state_machine do
    initial_states [:uninitialized]
    default_initial_state :uninitialized

    transitions do
      transition :provision, from: :uninitialized, to: :active
      transition :suspend, from: :active, to: :suspended
      transition :resume, from: :suspended, to: :active
      transition :terminate, from: [:active, :suspended], to: :terminated
    end
  end

  oban do
    triggers do
      # Suspend active sandboxes that haven't been used for 15+ minutes
      # Uses last_executed_at if available, otherwise falls back to inserted_at
      trigger :suspend_inactive do
        action :suspend
        queue :sandbox_maintenance
        scheduler_cron "*/5 * * * *"
        read_action :read_for_suspend
        worker_read_action :read_for_suspend
        worker_module_name Magus.Sandbox.Sandbox.Workers.SuspendInactive
        scheduler_module_name Magus.Sandbox.Sandbox.Schedulers.SuspendInactive

        where expr(
                state == :active and
                  (last_executed_at < ago(15, :minute) or
                     (is_nil(last_executed_at) and inserted_at < ago(15, :minute)))
              )

        max_attempts 3
      end

      # Terminate suspended sandboxes that haven't been used for 30+ days
      # Uses last_executed_at if available, otherwise falls back to inserted_at
      trigger :terminate_stale do
        action :terminate
        queue :sandbox_maintenance
        scheduler_cron "0 4 * * *"
        read_action :read_for_terminate
        worker_read_action :read_for_terminate
        worker_module_name Magus.Sandbox.Sandbox.Workers.TerminateStale
        scheduler_module_name Magus.Sandbox.Sandbox.Schedulers.TerminateStale

        where expr(
                state in [:active, :suspended] and
                  (last_executed_at < ago(30, :day) or
                     (is_nil(last_executed_at) and inserted_at < ago(30, :day)))
              )

        max_attempts 3
      end
    end
  end

  postgres do
    table "sandboxes"
    repo Magus.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept []
      argument :conversation_id, :uuid, allow_nil?: false

      change manage_relationship(:conversation_id, :conversation, type: :append)
      change set_attribute(:provider, &Magus.Sandbox.Provider.active_provider/0)
    end

    read :for_conversation do
      argument :conversation_id, :uuid, allow_nil?: false
      filter expr(conversation_id == ^arg(:conversation_id))
    end

    read :read_for_suspend do
      pagination keyset?: true, required?: false
    end

    read :read_for_terminate do
      pagination keyset?: true, required?: false
    end

    update :provision do
      description "Provision a Sprite and transition to active state"
      require_atomic? false

      change Magus.Sandbox.Sandbox.Changes.Provision
      change transition_state(:active)
    end

    update :suspend do
      description "Checkpoint the Sprite and transition to suspended state"
      require_atomic? false

      change Magus.Sandbox.Sandbox.Changes.Suspend
      change transition_state(:suspended)
    end

    update :resume do
      description "Restore from checkpoint and transition to active state"
      require_atomic? false

      change Magus.Sandbox.Sandbox.Changes.Resume
      change transition_state(:active)
    end

    update :terminate do
      description "Destroy the Sprite and transition to terminated state"
      require_atomic? false

      change Magus.Sandbox.Sandbox.Changes.Terminate
      change transition_state(:terminated)
    end

    update :set_service_port do
      accept [:service_port, :service_config]
    end

    update :record_execution do
      description "Update sandbox stats after code execution"
      accept []
      require_atomic? false

      argument :duration_ms, :integer, allow_nil?: false
      argument :cost_usd, :decimal, allow_nil?: false
      argument :workspace_files, {:array, :map}, allow_nil?: true

      change atomic_update(:total_executions, expr(total_executions + 1))
      change atomic_update(:total_cost_usd, expr(total_cost_usd + ^arg(:cost_usd)))
      change set_attribute(:last_executed_at, &DateTime.utc_now/0)
      change Magus.Sandbox.Sandbox.Changes.UpdateWorkspaceFiles
    end

    update :add_package do
      description "Track a newly installed package"
      accept []
      require_atomic? false

      argument :package, :string, allow_nil?: false

      change Magus.Sandbox.Sandbox.Changes.AddPackage
    end
  end

  policies do
    # AshOban triggers bypass authorization completely
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if expr(conversation.user_id == ^actor(:id))
      authorize_if Magus.Checks.IsAdmin
    end

    policy action_type(:create) do
      # Verify the actor owns the conversation they're creating a sandbox for
      authorize_if Magus.Sandbox.Sandbox.Checks.OwnsConversation
      authorize_if Magus.Checks.IsAdmin
    end

    policy action_type(:update) do
      authorize_if expr(conversation.user_id == ^actor(:id))
      authorize_if Magus.Checks.IsAdmin
    end

    policy action_type(:destroy) do
      authorize_if expr(conversation.user_id == ^actor(:id))
      authorize_if Magus.Checks.IsAdmin
    end
  end

  attributes do
    uuid_v7_primary_key :id

    # Provider
    attribute :provider, :atom,
      default: :sprites,
      public?: true,
      constraints: [one_of: [:sprites, :daytona, :test]]

    attribute :provider_data, :map, default: %{}, public?: true

    # Sprites.dev identifiers
    attribute :sprite_id, :string, public?: true
    attribute :sprite_url, :string, public?: true
    attribute :checkpoint_id, :string, public?: true

    # Tracking
    attribute :installed_packages, {:array, :string}, default: [], public?: true
    attribute :workspace_files, {:array, :map}, default: [], public?: true
    attribute :total_executions, :integer, default: 0, public?: true
    attribute :total_cost_usd, :decimal, default: Decimal.new("0"), public?: true
    attribute :service_port, :integer, public?: true
    attribute :service_config, :map, public?: true
    attribute :last_executed_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    belongs_to :conversation, Magus.Chat.Conversation, allow_nil?: false

    has_many :executions, Magus.Sandbox.Execution
  end

  identities do
    identity :unique_conversation, [:conversation_id]
  end
end
