defmodule MagusWeb.SettingsLive.IntegrationsLive do
  @moduledoc """
  Settings page for viewing user integrations.

  Integration setup is done in the Agent form. This page provides a read-only
  overview of all integrations with links to their bound agents, plus operational
  controls like Telegram chat approvals.
  """

  use MagusWeb, :live_view

  alias MagusWeb.Layouts
  alias Magus.Integrations

  on_mount {MagusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    case init_assigns(socket, user) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Failed to load integrations"))
         |> push_navigate(to: ~p"/settings")}
    end
  end

  @doc false
  def init_assigns(socket, user) do
    case Integrations.list_user_integrations(user.id, actor: user) do
      {:ok, integrations} ->
        {:ok,
         socket
         |> assign(:page_title, gettext("Integrations"))
         |> assign(:current_path, "/settings/integrations")
         |> assign(:integrations, integrations)}

      {:error, _reason} ->
        {:error, :load_failed}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} bg_class="bg-spectral">
      <:notification_bell>
        <.live_component
          module={MagusWeb.NotificationBellComponent}
          id="notification-bell"
          current_user={@current_user}
          unread_count={@unread_count}
        />
      </:notification_bell>

      <div class="container mx-auto max-w-4xl py-8 px-4">
        <h1 class="text-2xl font-bold mb-6">{gettext("Settings")}</h1>

        <.page_with_sidebar_nav nav_items={
          MagusWeb.SettingsLive.settings_nav_items(@current_path, @current_user)
        }>
          <div class="space-y-6">
            <p class="text-base-content/70">
              {gettext("Integrations are managed in each agent's settings.")}
              <.link navigate={~p"/agents"} class="link link-primary">
                {gettext("Go to Agents")}
              </.link>
            </p>

            <div :if={@integrations == []} class="text-center py-12 text-base-content/60">
              <.icon name="lucide-plug" class="w-12 h-12 mx-auto mb-3 opacity-30" />
              <p>{gettext("No integrations yet.")}</p>
              <p class="text-sm mt-1">
                {gettext("Add a Telegram bot in an agent's settings to get started.")}
              </p>
            </div>

            <div class="space-y-4">
              <%= for integration <- @integrations do %>
                <.integration_row integration={integration} />
              <% end %>
            </div>
          </div>
        </.page_with_sidebar_nav>
      </div>
    </Layouts.app>
    """
  end

  @doc false
  def render_integrations_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <p class="text-base-content/70">
        {gettext("Integrations are managed in each agent's settings.")}
        <.link navigate={~p"/agents"} class="link link-primary">
          {gettext("Go to Agents")}
        </.link>
      </p>

      <div :if={@integrations == []} class="text-center py-12 text-base-content/60">
        <.icon name="lucide-plug" class="w-12 h-12 mx-auto mb-3 opacity-30" />
        <p>{gettext("No integrations yet.")}</p>
        <p class="text-sm mt-1">
          {gettext("Add a Telegram bot in an agent's settings to get started.")}
        </p>
      </div>

      <div class="space-y-4">
        <%= for integration <- @integrations do %>
          <.integration_row integration={integration} />
        <% end %>
      </div>
    </div>
    """
  end

  attr :integration, :map, required: true

  defp integration_row(assigns) do
    config = assigns.integration.config || %{}
    agent = assigns.integration.custom_agent
    agent_name = if agent && !match?(%Ash.NotLoaded{}, agent), do: agent.name, else: nil

    assigns =
      assigns
      |> assign(:agent_name, agent_name)
      |> assign(:agent_id, if(agent && !match?(%Ash.NotLoaded{}, agent), do: agent.id))
      |> assign(:bot_username, config["bot_username"])
      |> assign(:pending_approvals, config["pending_approvals"] || [])
      |> assign(:allowed_chat_ids, config["allowed_chat_ids"] || [])

    ~H"""
    <div class="card bg-base-200 border border-base-300">
      <div class="card-body p-4">
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-3">
            <.provider_icon provider={@integration.provider_key} />
            <div>
              <div class="flex items-center gap-2">
                <h3 class="font-semibold">{provider_label(@integration.provider_key)}</h3>
                <.status_badge status={@integration.status} />
              </div>
              <p :if={@bot_username} class="text-sm text-primary">@{@bot_username}</p>
              <p :if={@agent_name} class="text-xs text-base-content/60">
                {gettext("Agent: %{name}", name: @agent_name)}
              </p>
            </div>
          </div>

          <.link
            :if={@agent_id}
            navigate={"/agents/#{@agent_id}?edit=true&section=integrations"}
            class="btn btn-sm btn-ghost"
          >
            <.icon name="lucide-settings" class="w-4 h-4" />
            {gettext("Edit Agent")}
          </.link>
        </div>

        <%!-- Telegram pending approvals --%>
        <div
          :if={@integration.provider_key == :telegram && length(@pending_approvals) > 0}
          class="border-t border-base-300 pt-3 mt-3"
        >
          <p class="text-sm font-medium mb-2">
            <.icon name="lucide-clock" class="w-4 h-4 inline" />
            {gettext("Pending Approvals")}
            <span class="badge badge-sm badge-warning ml-1">{length(@pending_approvals)}</span>
          </p>
          <div class="space-y-2">
            <%= for entry <- @pending_approvals do %>
              <div class="flex items-center justify-between p-2 bg-base-300 rounded-lg">
                <div>
                  <p class="text-sm font-medium">
                    {entry["sender_name"] || gettext("Unknown")}
                    <span :if={entry["sender_username"]} class="text-xs opacity-70">
                      @{entry["sender_username"]}
                    </span>
                  </p>
                  <p class="text-xs opacity-50">
                    {gettext("Chat ID: %{id}", id: entry["chat_id"])}
                  </p>
                </div>
                <div class="flex gap-1">
                  <button
                    phx-click="approve_chat"
                    phx-value-integration-id={@integration.id}
                    phx-value-chat-id={entry["chat_id"]}
                    class="btn btn-xs btn-success btn-outline"
                  >
                    <.icon name="lucide-check" class="w-3 h-3" />
                  </button>
                  <button
                    phx-click="deny_chat"
                    phx-value-integration-id={@integration.id}
                    phx-value-chat-id={entry["chat_id"]}
                    class="btn btn-xs btn-error btn-outline"
                  >
                    <.icon name="lucide-x" class="w-3 h-3" />
                  </button>
                </div>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Telegram allowed chats --%>
        <div
          :if={@integration.provider_key == :telegram && length(@allowed_chat_ids) > 0}
          class="border-t border-base-300 pt-3 mt-3"
        >
          <p class="text-sm font-medium mb-2">
            <.icon name="lucide-shield-check" class="w-4 h-4 inline" />
            {gettext("Allowed Chats")}
          </p>
          <div class="flex flex-wrap gap-2">
            <%= for chat_id <- @allowed_chat_ids do %>
              <div class="badge badge-outline gap-1">
                {chat_id}
                <button
                  phx-click="remove_chat"
                  phx-value-integration-id={@integration.id}
                  phx-value-chat-id={chat_id}
                  class="hover:text-error"
                >
                  <.icon name="lucide-x" class="w-3 h-3" />
                </button>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :provider, :atom, required: true

  defp provider_icon(assigns) do
    icon_name =
      case assigns.provider do
        :telegram -> "lucide-send"
        :google_calendar -> "lucide-calendar"
        :email -> "lucide-mail"
        :discord -> "lucide-message-circle"
        :slack -> "lucide-hash"
        :whatsapp -> "lucide-message-square"
        _ -> "lucide-plug"
      end

    assigns = assign(assigns, :icon_name, icon_name)

    ~H"""
    <div class="w-10 h-10 rounded-full bg-primary/10 flex items-center justify-center">
      <.icon name={@icon_name} class="w-5 h-5 text-primary" />
    </div>
    """
  end

  attr :status, :atom, required: true

  defp status_badge(assigns) do
    {class, label} =
      case assigns.status do
        :active -> {"badge-success", gettext("Active")}
        :pending -> {"badge-warning", gettext("Pending")}
        :error -> {"badge-error", gettext("Error")}
        _ -> {"badge-ghost", gettext("Inactive")}
      end

    assigns = assign(assigns, class: class, label: label)

    ~H"""
    <span class={"badge badge-sm #{@class}"}>{@label}</span>
    """
  end

  defp provider_label(:telegram), do: "Telegram"
  defp provider_label(:simple_webhook), do: "Simple Webhook"

  defp provider_label(key),
    do: key |> to_string() |> String.replace("_", " ") |> String.capitalize()

  # Event handlers — Telegram chat management

  @impl true
  def handle_event(
        "approve_chat",
        %{"integration-id" => integration_id, "chat-id" => chat_id},
        socket
      ) do
    update_chat_config(socket, integration_id, fn config ->
      pending = config["pending_approvals"] || []
      allowed = config["allowed_chat_ids"] || []

      new_pending = Enum.reject(pending, &(&1["chat_id"] == chat_id))
      new_allowed = if chat_id in allowed, do: allowed, else: allowed ++ [chat_id]

      config
      |> Map.put("pending_approvals", new_pending)
      |> Map.put("allowed_chat_ids", new_allowed)
    end)
  end

  @impl true
  def handle_event(
        "deny_chat",
        %{"integration-id" => integration_id, "chat-id" => chat_id},
        socket
      ) do
    update_chat_config(socket, integration_id, fn config ->
      pending = config["pending_approvals"] || []
      Map.put(config, "pending_approvals", Enum.reject(pending, &(&1["chat_id"] == chat_id)))
    end)
  end

  @impl true
  def handle_event(
        "remove_chat",
        %{"integration-id" => integration_id, "chat-id" => chat_id},
        socket
      ) do
    update_chat_config(socket, integration_id, fn config ->
      allowed = config["allowed_chat_ids"] || []
      Map.put(config, "allowed_chat_ids", Enum.reject(allowed, &(&1 == chat_id)))
    end)
  end

  defp update_chat_config(socket, integration_id, update_fn) do
    integration = Enum.find(socket.assigns.integrations, &(&1.id == integration_id))

    if integration do
      config = integration.config || %{}
      new_config = update_fn.(config)

      case Integrations.update_integration_config(
             integration,
             %{config: new_config},
             actor: socket.assigns.current_user
           ) do
        {:ok, updated} ->
          updated =
            Ash.load!(updated, [:provider_key, :custom_agent], actor: socket.assigns.current_user)

          integrations =
            Enum.map(socket.assigns.integrations, fn i ->
              if i.id == updated.id, do: updated, else: i
            end)

          {:noreply, assign(socket, :integrations, integrations)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to update configuration"))}
      end
    else
      {:noreply, socket}
    end
  end
end
