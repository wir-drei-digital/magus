defmodule MagusWeb.Hooks.NotificationSubscription do
  @moduledoc """
  LiveView on_mount hook that subscribes to notification PubSub events
  and manages the `unread_count` assign for the notification bell.

  Attach via `on_mount` in the router's authenticated live session.
  Uses `attach_hook/4` to intercept `handle_info` messages so individual
  LiveViews don't need any notification-specific code.
  """
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) && socket.assigns[:current_user] do
      user_id = socket.assigns.current_user.id
      Magus.Endpoint.subscribe(Magus.Notifications.topic(user_id))

      count =
        case Magus.Notifications.unread_notification_count(user_id) do
          {:ok, c} -> c
          _ -> 0
        end

      socket =
        socket
        |> assign(:unread_count, count)
        |> attach_hook(:notification_handler, :handle_info, &handle_notification/2)

      {:cont, socket}
    else
      {:cont, assign(socket, :unread_count, 0)}
    end
  end

  # Ash PubSub broadcasts for :create action
  defp handle_notification(
         %Phoenix.Socket.Broadcast{topic: "notifications:" <> _, event: "create"},
         socket
       ) do
    count = socket.assigns.unread_count + 1
    maybe_send_update(new_notification: true)
    {:halt, assign(socket, :unread_count, count)}
  end

  # Ash PubSub broadcasts for :mark_read action
  defp handle_notification(
         %Phoenix.Socket.Broadcast{topic: "notifications:" <> _, event: "mark_read"},
         socket
       ) do
    count = refetch_unread_count(socket)
    maybe_send_update(refresh: true)
    {:halt, assign(socket, :unread_count, count)}
  end

  # Manual broadcast from NotificationBellComponent for mark_all_read (generic action)
  defp handle_notification(
         %Phoenix.Socket.Broadcast{topic: "notifications:" <> _, event: "notification_read"},
         socket
       ) do
    count = refetch_unread_count(socket)
    maybe_send_update(refresh: true)
    {:halt, assign(socket, :unread_count, count)}
  end

  defp handle_notification(_other, socket), do: {:cont, socket}

  defp refetch_unread_count(socket) do
    case socket.assigns[:current_user] do
      %{id: user_id} ->
        case Magus.Notifications.unread_notification_count(user_id) do
          {:ok, c} -> c
          _ -> 0
        end

      _ ->
        0
    end
  end

  # send_update is safe to call even if the component isn't mounted —
  # Phoenix silently discards updates to non-existent components.
  # We wrap it here for clarity and to keep the notification handlers clean.
  defp maybe_send_update(assigns) do
    send_update(MagusWeb.NotificationBellComponent, [{:id, "notification-bell"} | assigns])
  end
end
