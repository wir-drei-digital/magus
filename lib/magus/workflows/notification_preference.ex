defmodule Magus.Workflows.NotificationPreference do
  @moduledoc """
  Notification preferences for a Job.

  Controls when and how users are notified about job execution results.
  Each job can have one notification preference record.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Workflows,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "job_notification_preferences"
    repo Magus.Repo

    migration_defaults notification_channels: "\"nil\""
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:notify_on_success, :notify_on_failure, :notification_channels]
      argument :job_id, :uuid, allow_nil?: false

      change set_attribute(:job_id, arg(:job_id))
    end

    update :update do
      accept [:notify_on_success, :notify_on_failure, :notification_channels]
    end
  end

  policies do
    # AshOban triggers bypass authorization
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # AI Agent can manage notification preferences
    bypass action_type([:read, :create, :update]) do
      authorize_if Magus.Checks.IsAiAgent
    end

    # Users can read/manage preferences for their jobs
    policy action_type(:read) do
      authorize_if expr(exists(job, user_id == ^actor(:id)))
    end

    # Create uses custom check since relationship doesn't exist yet
    policy action_type(:create) do
      authorize_if Magus.Checks.OwnsJob
    end

    policy action_type([:update, :destroy]) do
      authorize_if expr(exists(job, user_id == ^actor(:id)))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :notify_on_success, :boolean, default: false, public?: true
    attribute :notify_on_failure, :boolean, default: true, public?: true

    attribute :notification_channels, {:array, :atom} do
      constraints items: [one_of: [:in_app, :email]]
      default [:in_app]
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :job, Magus.Workflows.Job, allow_nil?: false
  end

  identities do
    identity :unique_per_job, [:job_id]
  end
end
