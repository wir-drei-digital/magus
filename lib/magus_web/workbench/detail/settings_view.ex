defmodule MagusWeb.Workbench.Detail.SettingsView do
  @moduledoc """
  Settings detail-view LiveView, rendered inside the workbench main area
  via live_render. Owns the actual form/save/upload logic; the workbench
  nav-pane shows the Settings sub-nav (Profile, Preferences, Storage,
  Data, Subscription, Integrations, Knowledge).

  The active section is passed as a mount param. SettingsView delegates
  to the legacy MagusWeb.SettingsLive (and its sibling Integrations and
  Knowledge LiveViews) for assign-loading and rendering; the Subscription
  section goes through the MagusWeb.Workbench.Detail.SubscriptionSection
  seam so the always-loaded workbench stays free of Magus.Billing. Outer
  Layouts.app chrome is dropped here.
  """
  use MagusWeb, :live_view

  on_mount({MagusWeb.LiveUserAuth, :restore_locale})

  @sections ~w(profile preferences storage data subscription integrations knowledge usage)a

  @impl true
  def mount(_params, %{"section" => section_str, "user_id" => user_id}, socket) do
    user = Magus.Accounts.get_user!(user_id, authorize?: false)
    section = parse_section(section_str)

    socket =
      socket
      |> assign(:current_user, user)
      |> assign(:section, section)
      |> MagusWeb.SettingsLive.init_assigns(user)
      |> maybe_init_section_assigns(section, user)

    {:ok, socket}
  end

  defp parse_section(str) when is_binary(str) do
    atom = String.to_existing_atom(str)
    if atom in @sections, do: atom, else: :profile
  rescue
    ArgumentError -> :profile
  end

  defp parse_section(_), do: :profile

  defp maybe_init_section_assigns(socket, :subscription, user) do
    case MagusWeb.Workbench.Detail.SubscriptionSection.init_assigns(socket, user) do
      {:ok, socket} -> assign(socket, :subscription_unavailable, false)
      {:error, _} -> assign(socket, :subscription_unavailable, true)
    end
  end

  defp maybe_init_section_assigns(socket, :integrations, user) do
    case MagusWeb.SettingsLive.IntegrationsLive.init_assigns(socket, user) do
      {:ok, socket} -> socket
      {:error, _} -> socket
    end
  end

  defp maybe_init_section_assigns(socket, :knowledge, user),
    do: MagusWeb.SettingsLive.KnowledgeLive.init_assigns(socket, user)

  defp maybe_init_section_assigns(socket, :usage, user),
    do: MagusWeb.Workbench.Detail.UsageSection.init_assigns(socket, user)

  defp maybe_init_section_assigns(socket, _, _), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="h-full overflow-y-auto"
      data-settings-section={@section}
      data-locale={Gettext.get_locale(MagusWeb.Gettext)}
    >
      <div class="container mx-auto max-w-4xl py-8 px-4 space-y-6">
        <%= case @section do %>
          <% :profile -> %>
            {MagusWeb.SettingsLive.render_profile_section(assigns)}
          <% :preferences -> %>
            {MagusWeb.SettingsLive.render_preferences_section(assigns)}
          <% :storage -> %>
            {MagusWeb.SettingsLive.render_storage_section(assigns)}
          <% :data -> %>
            {MagusWeb.SettingsLive.render_data_section(assigns)}
          <% :subscription -> %>
            <%= if assigns[:subscription_unavailable] do %>
              <p class="text-base-content/70">
                {gettext("Subscription not found. Please contact support.")}
              </p>
            <% else %>
              {MagusWeb.Workbench.Detail.SubscriptionSection.render_section(assigns)}
            <% end %>
          <% :integrations -> %>
            {MagusWeb.SettingsLive.IntegrationsLive.render_integrations_section(assigns)}
          <% :knowledge -> %>
            {MagusWeb.SettingsLive.KnowledgeLive.render_knowledge_section(assigns)}
          <% :usage -> %>
            {MagusWeb.Workbench.Detail.UsageSection.render_section(assigns)}
        <% end %>
      </div>
    </div>
    """
  end

  # Delegate events to the appropriate legacy LiveView based on which section
  # owns them. Profile/Preferences/Storage/Data events live in SettingsLive.
  # Subscription and Integrations each route to their own module.
  # Knowledge has no handle_event — its events fall through to SettingsLive.

  @impl true
  def handle_event(event, params, %{assigns: %{section: :subscription}} = socket),
    do: MagusWeb.Workbench.Detail.SubscriptionSection.handle_event(event, params, socket)

  def handle_event(event, params, %{assigns: %{section: :integrations}} = socket),
    do: MagusWeb.SettingsLive.IntegrationsLive.handle_event(event, params, socket)

  def handle_event(event, params, %{assigns: %{section: :usage}} = socket),
    do: MagusWeb.Workbench.Detail.UsageSection.handle_event(event, params, socket)

  def handle_event(event, params, socket),
    do: MagusWeb.SettingsLive.handle_event(event, params, socket)

  # KnowledgeLive has public handle_info clauses — delegate to it.
  # Subscription and Integrations have no handle_info — fall through to SettingsLive.

  @impl true
  def handle_info(msg, %{assigns: %{section: :knowledge}} = socket),
    do: MagusWeb.SettingsLive.KnowledgeLive.handle_info(msg, socket)

  def handle_info(msg, socket),
    do: MagusWeb.SettingsLive.handle_info(msg, socket)
end
