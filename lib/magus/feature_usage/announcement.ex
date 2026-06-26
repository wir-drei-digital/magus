defmodule Magus.FeatureUsage.Announcement do
  @moduledoc """
  Represents a feature announcement that can be shown to users.

  Announcements track "seen" state by reusing FeatureUsageEvent records —
  when a user dismisses an announcement, we call
  `track(user_id, "announcement", "seen", %{"announcement_id" => key})`.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.FeatureUsage,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshTypescript.Resource]

  postgres do
    table "announcements"
    repo Magus.Repo
  end

  typescript do
    type_name "Announcement"
  end

  actions do
    defaults [:read]

    create :create do
      accept [:key, :title, :description, :icon, :action_type, :action_payload]
    end

    read :active do
      filter expr(active == true)
      prepare build(sort: [inserted_at: :desc])
    end

    action :unseen_announcements, {:array, :map} do
      description "Active announcements the actor has not yet dismissed, localized for the actor."

      run fn _input, ctx ->
        case ctx.actor do
          nil ->
            {:error, "authentication required"}

          actor ->
            {:ok,
             Magus.FeatureUsage.unseen_announcement_cards(actor.id, to_string(actor.language))}
        end
      end
    end

    action :dismiss_announcement, :atom do
      description "Record that the actor dismissed (saw) an announcement, by key."
      constraints one_of: [:ok]
      argument :key, :string, allow_nil?: false

      run fn input, ctx ->
        case ctx.actor do
          nil ->
            {:error, "authentication required"}

          actor ->
            Magus.FeatureUsage.mark_announcement_seen(actor.id, input.arguments.key)
            {:ok, :ok}
        end
      end
    end

    update :update do
      accept [:key, :title, :description, :icon, :action_type, :action_payload, :active]
    end

    update :deactivate do
      change set_attribute(:active, false)
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :key, :string, allow_nil?: false, public?: true
    attribute :title, :map, allow_nil?: false, public?: true
    attribute :description, :map, allow_nil?: false, public?: true
    attribute :icon, :string, default: "", public?: true
    attribute :action_type, :string, allow_nil?: false, public?: true
    attribute :action_payload, :string, allow_nil?: false, public?: true
    attribute :active, :boolean, default: true, allow_nil?: false

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_key, [:key]
  end
end
