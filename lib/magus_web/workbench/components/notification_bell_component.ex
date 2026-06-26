defmodule MagusWeb.NotificationBellComponent do
  @moduledoc """
  LiveComponent that renders the notification bell with an interactive dropdown.

  Receives `unread_count` from the parent (managed by the NotificationSubscription hook)
  and handles dropdown state, fetching notifications, marking as read, and navigation.

  Uses `header_dropdown` in live mode for consistent styling with other header dropdowns.
  """
  use MagusWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, assign(socket, open?: false, notifications: [], grouped: [])}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    should_refresh? =
      socket.assigns.open? and (assigns[:new_notification] || assigns[:refresh])

    if should_refresh?,
      do: {:ok, fetch_and_group(socket)},
      else: {:ok, socket}
  end

  @impl true
  def handle_event("toggle", _params, socket) do
    open? = !socket.assigns.open?

    socket =
      if open? do
        fetch_and_group(socket)
      else
        socket
      end

    {:noreply, assign(socket, :open?, open?)}
  end

  @impl true
  def handle_event("close", _params, socket) do
    {:noreply, assign(socket, :open?, false)}
  end

  @impl true
  def handle_event("mark_read", %{"id" => id}, socket) do
    mark_group_read(socket, id)
    {:noreply, socket}
  end

  @impl true
  def handle_event("mark_all_read", _params, socket) do
    user = socket.assigns.current_user
    Magus.Notifications.mark_all_notifications_read(actor: user)
    broadcast_read(user.id)
    {:noreply, socket}
  end

  @impl true
  def handle_event("navigate", %{"id" => id}, socket) do
    notification = mark_group_read(socket, id)

    path =
      cond do
        notification && notification.metadata["navigate_to"] ->
          notification.metadata["navigate_to"]

        notification && notification.target_conversation_id ->
          "/chat/#{notification.target_conversation_id}"

        true ->
          "/chat"
      end

    {:noreply, push_navigate(socket, to: path)}
  end

  @impl true
  def render(assigns) do
    assigns = assign_new(assigns, :placement, fn -> "down-end" end)

    ~H"""
    <div>
      <.header_dropdown
        open={@open?}
        target={@myself}
        placement={@placement}
        aria_label={
          ngettext(
            "1 unread notification",
            "%{count} unread notifications",
            @unread_count
          )
        }
        width_class="w-80"
        panel_class="max-h-96 overflow-y-auto"
      >
        <:trigger>
          <.icon name="lucide-bell" class="w-4 h-4 text-base-content/70" />
          <span
            :if={@unread_count > 0}
            class="absolute -top-0.5 -right-0.5 flex items-center justify-center min-w-[18px] h-[18px] px-1 text-[10px] font-bold text-primary-content bg-primary rounded-full"
          >
            {if @unread_count > 99, do: "99+", else: @unread_count}
          </span>
        </:trigger>
        <:panel>
          <%!-- Header --%>
          <div class="flex items-center justify-between px-4 py-3 ">
            <h3 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-3">
              {gettext("Notifications")}
            </h3>
            <button
              :if={@notifications != []}
              phx-click="mark_all_read"
              phx-target={@myself}
              class="text-xs text-primary hover:underline cursor-pointer mb-3"
            >
              {gettext("Mark all as read")}
            </button>
          </div>

          <%!-- Notification list --%>
          <%= if @notifications == [] do %>
            <div class="px-4 py-8 text-center">
              <.icon name="lucide-bell-off" class="w-8 h-8 text-base-content/30 mx-auto mb-2" />
              <p class="text-sm text-base-content/50">{gettext("No unread notifications")}</p>
            </div>
          <% else %>
            <ul class="divide-y divide-base-300">
              <%= for {_conv_id, group} <- @grouped do %>
                <% primary = hd(group) %>
                <% count = length(group) %>
                <li class="hover:bg-base-200/50 transition-colors">
                  <%= if primary.target_conversation_id || (primary.metadata || %{})["navigate_to"] do %>
                    <button
                      phx-click="navigate"
                      phx-target={@myself}
                      phx-value-id={primary.id}
                      class="w-full text-left px-4 py-3 flex items-start gap-3"
                    >
                      <.notification_content notification={primary} count={count} />
                    </button>
                  <% else %>
                    <div class="px-4 py-3 flex items-start gap-3">
                      <.notification_content notification={primary} count={count} />
                      <button
                        phx-click="mark_read"
                        phx-target={@myself}
                        phx-value-id={primary.id}
                        class="flex-shrink-0 mt-1 p-1 rounded hover:bg-base-300 transition-colors"
                        title={gettext("Mark as read")}
                      >
                        <.icon name="lucide-x" class="w-3 h-3 text-base-content/40" />
                      </button>
                    </div>
                  <% end %>
                </li>
              <% end %>
            </ul>
          <% end %>
        </:panel>
      </.header_dropdown>
    </div>
    """
  end

  # --- Private Components ---

  attr :notification, :map, required: true
  attr :count, :integer, required: true

  defp notification_content(assigns) do
    ~H"""
    <div class={"flex-shrink-0 mt-0.5 w-7 h-7 rounded-full flex items-center justify-center #{notification_icon_bg(@notification.notification_type)}"}>
      <.icon name={notification_icon(@notification.notification_type)} class="w-3.5 h-3.5" />
    </div>
    <div class="flex-1 min-w-0">
      <p class="text-sm font-medium text-base-content truncate">
        {@notification.title || notification_title(@notification.notification_type)}
      </p>
      <p :if={@notification.body} class="text-xs text-base-content/60 truncate">
        {@notification.body}
      </p>
      <div class="flex items-center gap-2 mt-1">
        <span class="text-xs text-base-content/40">
          {format_relative_time(@notification.inserted_at)}
        </span>
        <span :if={@count > 1} class="text-xs text-primary font-medium">
          +{@count - 1}
        </span>
      </div>
    </div>
    """
  end

  # --- Data Helpers ---

  defp fetch_and_group(socket) do
    user = socket.assigns.current_user

    notifications =
      case Magus.Notifications.list_unread_notifications(actor: user) do
        {:ok, list} -> list
        _ -> []
      end

    grouped =
      notifications
      |> Enum.group_by(fn n ->
        n.target_conversation_id || (n.metadata || %{})["navigate_to"] || :no_conversation
      end)
      |> Enum.sort_by(fn {_k, group} -> hd(group).inserted_at end, {:desc, DateTime})

    assign(socket, notifications: notifications, grouped: grouped)
  end

  defp mark_group_read(socket, notification_id) do
    user = socket.assigns.current_user
    notification = Enum.find(socket.assigns.notifications, &(&1.id == notification_id))

    if notification do
      conv_id =
        notification.target_conversation_id ||
          (notification.metadata || %{})["navigate_to"] ||
          :no_conversation

      group =
        case Enum.find(socket.assigns.grouped, fn {k, _} -> k == conv_id end) do
          {_, items} -> items
          nil -> [notification]
        end

      Enum.each(group, fn n ->
        Magus.Notifications.mark_notification_read(n, actor: user)
      end)

      broadcast_read(user.id)
    end

    notification
  end

  # --- PubSub ---

  defp broadcast_read(user_id) do
    Magus.Endpoint.broadcast(
      Magus.Notifications.topic(user_id),
      "notification_read",
      %{user_id: user_id}
    )
  end

  # --- Formatting ---

  defp notification_title(:task_update), do: gettext("Task Update")
  defp notification_title(:task_completed), do: gettext("Task Completed")
  defp notification_title(:mention), do: gettext("Mention")
  defp notification_title(:message), do: gettext("New Response")
  defp notification_title(:system), do: gettext("System Notification")
  defp notification_title(:approval_request), do: gettext("Approval Request")
  defp notification_title(_), do: gettext("Notification")

  defp notification_icon(:task_update), do: "lucide-refresh-cw"
  defp notification_icon(:task_completed), do: "lucide-check-circle"
  defp notification_icon(:mention), do: "lucide-at-sign"
  defp notification_icon(:message), do: "lucide-message-square"
  defp notification_icon(:approval_request), do: "lucide-user-check"
  defp notification_icon(_), do: "lucide-bell"

  defp notification_icon_bg(:task_update), do: "bg-info/20 text-info"
  defp notification_icon_bg(:task_completed), do: "bg-success/20 text-success"
  defp notification_icon_bg(:mention), do: "bg-warning/20 text-warning"
  defp notification_icon_bg(:message), do: "bg-primary/20 text-primary"
  defp notification_icon_bg(:approval_request), do: "bg-warning/20 text-warning"
  defp notification_icon_bg(_), do: "bg-base-300 text-base-content/50"

  defp format_relative_time(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> gettext("just now")
      diff < 3600 -> gettext("%{n}m ago", n: div(diff, 60))
      diff < 86400 -> gettext("%{n}h ago", n: div(diff, 3600))
      true -> gettext("%{n}d ago", n: div(diff, 86400))
    end
  end
end
