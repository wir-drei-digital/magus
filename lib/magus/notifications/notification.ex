defmodule Magus.Notifications.Notification do
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Notifications,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub],
    extensions: [AshTypescript.Resource]

  postgres do
    table "notifications"
    repo Magus.Repo

    custom_indexes do
      index [:user_id, :read_at]
    end
  end

  typescript do
    type_name "Notification"
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
    end

    create :create do
      accept [:title, :body, :notification_type, :target_conversation_id, :metadata, :user_id]
    end

    read :unread do
      filter expr(is_nil(read_at) and user_id == ^actor(:id))
      prepare build(sort: [inserted_at: :desc], limit: 20)
    end

    update :mark_read do
      accept []
      require_atomic? false

      change set_attribute(:read_at, &DateTime.utc_now/0)
    end

    action :mark_all_read, :integer do
      run fn _input, context ->
        require Ash.Query

        __MODULE__
        |> Ash.Query.filter(user_id == ^context.actor.id and is_nil(read_at))
        |> Ash.bulk_update!(:mark_read, %{}, actor: context.actor, return_errors?: true)

        {:ok, 0}
      end
    end

    action :unread_count, :integer do
      argument :user_id, :uuid, allow_nil?: false

      run fn input, _context ->
        require Ash.Query

        count =
          __MODULE__
          |> Ash.Query.filter(user_id == ^input.arguments.user_id and is_nil(read_at))
          |> Ash.count!(authorize?: false)

        {:ok, count}
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action_type(:update) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action_type(:create) do
      authorize_if always()
    end

    policy action(:mark_all_read) do
      authorize_if actor_present()
    end

    policy action(:unread_count) do
      authorize_if always()
    end
  end

  pub_sub do
    module MagusWeb.Endpoint
    prefix "notifications"

    publish :create, [:user_id] do
      transform fn %{data: notification} ->
        %{
          id: notification.id,
          title: notification.title,
          body: notification.body,
          notification_type: notification.notification_type,
          target_conversation_id: notification.target_conversation_id,
          user_id: notification.user_id
        }
      end
    end

    publish :mark_read, [:user_id] do
      transform fn %{data: notification} ->
        %{
          id: notification.id,
          user_id: notification.user_id
        }
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :title, :string do
      allow_nil? true
      public? true

      description "Optional custom title override. If nil, UI derives title from notification_type."
    end

    attribute :body, :string do
      allow_nil? true
      public? true
    end

    attribute :notification_type, :atom do
      allow_nil? false
      default :system

      constraints one_of: [
                    :task_update,
                    :task_completed,
                    :mention,
                    :message,
                    :system,
                    :approval_request,
                    :workspace_invite,
                    :workspace_role_changed,
                    :workspace_removed,
                    :workspace_ownership_transferred
                  ]

      public? true
    end

    attribute :read_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :metadata, :map do
      allow_nil? true
      default %{}
      public? true
    end

    attribute :target_conversation_id, :uuid do
      allow_nil? true
      public? true
    end

    timestamps public?: true
  end

  relationships do
    belongs_to :user, Magus.Accounts.User do
      public? true
      allow_nil? false
    end
  end
end
