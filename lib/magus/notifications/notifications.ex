defmodule Magus.Notifications do
  @moduledoc """
  Notifications domain: user-facing notifications, delivered to the shell
  notification bell with live inserts over the user channel.
  """

  use Ash.Domain, otp_app: :magus, extensions: [AshTypescript.Rpc]

  typescript_rpc do
    # Shell notification bell: initial unread list + read receipts. Live
    # inserts arrive over the user channel (`notification.create`).
    resource Magus.Notifications.Notification do
      rpc_action :unread_notifications, :unread
      rpc_action :mark_notification_read, :mark_read
      rpc_action :mark_all_notifications_read, :mark_all_read
    end
  end

  @doc "PubSub topic for a user's notifications."
  def topic(user_id), do: "notifications:#{user_id}"

  resources do
    resource Magus.Notifications.Notification do
      define :create_notification, action: :create
      define :list_unread_notifications, action: :unread
      define :mark_notification_read, action: :mark_read
      define :mark_all_notifications_read, action: :mark_all_read
      define :unread_notification_count, action: :unread_count, args: [:user_id]
    end
  end
end
