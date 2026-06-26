defmodule Magus.FeatureUsage.FeatureUsageEvent do
  @moduledoc """
  Tracks feature usage events for onboarding and analytics.

  Each event records a user interacting with a specific feature/action pair,
  with optional metadata for additional context.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.FeatureUsage,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshTypescript.Resource]

  require Ash.Query

  postgres do
    table "feature_usage_events"
    repo Magus.Repo
  end

  typescript do
    type_name "FeatureUsageEvent"
  end

  actions do
    read :read do
      primary? true
    end

    action :onboarding_cards, :map do
      description "Undiscovered onboarding feature cards (localized) + first_time flag for the new-chat landing."

      run fn _input, ctx ->
        case ctx.actor do
          nil ->
            {:error, "authentication required"}

          actor ->
            {:ok, Magus.FeatureUsage.onboarding_cards(actor.id, to_string(actor.language))}
        end
      end
    end

    create :track do
      description "Track a feature usage event"
      accept [:feature, :action, :metadata]

      argument :user_id, :uuid, allow_nil?: false

      change set_attribute(:user_id, arg(:user_id))
      change Magus.FeatureUsage.Changes.BroadcastUsage
    end

    read :for_user do
      description "List all feature usage events for the current actor"

      prepare build(sort: [inserted_at: :desc])

      filter expr(user_id == ^actor(:id))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :feature, :string, allow_nil?: false, public?: true
    attribute :action, :string, allow_nil?: false, public?: true
    attribute :metadata, :map, default: %{}, public?: true
    attribute :user_id, :uuid, allow_nil?: false

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :user, Magus.Accounts.User do
      attribute_writable? true
      define_attribute? false
    end
  end
end
