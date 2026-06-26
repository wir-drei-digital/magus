defmodule MagusWeb.ChatLive.Components.Participants.UIHelpers do
  @moduledoc """
  Shared UI helper components for the participants sidebar.

  Contains reusable function components for member items, invitation items, and role display.
  """
  use Phoenix.Component
  use Gettext, backend: MagusWeb.Gettext

  import MagusWeb.CoreComponents

  @doc """
  Renders a member list item with avatar, name, role, and action dropdown.
  """
  attr :member, :map, required: true
  attr :is_owner, :boolean, default: false
  attr :myself, :any, required: true

  def member_item(assigns) do
    ~H"""
    <div
      id={"member-#{@member.id}"}
      class="flex items-center gap-3 p-2 rounded-lg hover:bg-base-200 transition-colors"
    >
      <%!-- Avatar --%>
      <.user_avatar user={@member.user} size="sm" />

      <%!-- User Info --%>
      <div class="flex-1 min-w-0">
        <div class="text-sm font-medium truncate">
          {display_name(@member.user)}
        </div>
        <div class="flex items-center gap-1 text-xs text-base-content/60">
          <span class={"badge badge-xs #{role_badge_class(@member.role)}"}>
            {role_label(@member.role)}
          </span>
          <span :if={@member.is_muted} class="badge badge-xs badge-warning">
            {gettext("muted")}
          </span>
          <span :if={is_nil(@member.accepted_at)} class="badge badge-xs badge-ghost">
            {gettext("pending")}
          </span>
        </div>
      </div>

      <%!-- Actions Dropdown (Owner only, not for self) --%>
      <div
        :if={@is_owner && @member.role != :owner}
        class="dropdown dropdown-end"
      >
        <label tabindex="0" class="btn btn-ghost btn-xs btn-square">
          <.icon name="lucide-more-vertical" class="w-4 h-4" />
        </label>
        <ul
          tabindex="0"
          class="dropdown-content z-50 menu menu-xs shadow bg-base-100 rounded-box w-36"
        >
          <li :if={!@member.is_muted}>
            <button
              phx-click="mute_member"
              phx-value-id={@member.id}
              phx-target={@myself}
            >
              <.icon name="lucide-volume-x" class="w-3 h-3" /> {gettext("Mute")}
            </button>
          </li>
          <li :if={@member.is_muted}>
            <button
              phx-click="unmute_member"
              phx-value-id={@member.id}
              phx-target={@myself}
            >
              <.icon name="lucide-volume-2" class="w-3 h-3" /> {gettext("Unmute")}
            </button>
          </li>
          <li>
            <button
              phx-click="show_role_modal"
              phx-value-id={@member.id}
              phx-target={@myself}
            >
              <.icon name="lucide-shield-check" class="w-3 h-3" /> {gettext("Change Role")}
            </button>
          </li>
          <li>
            <button
              phx-click="kick_member"
              phx-value-id={@member.id}
              phx-target={@myself}
              class="text-error"
            >
              <.icon name="lucide-user-minus" class="w-3 h-3" /> {gettext("Remove")}
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  @doc """
  Renders a pending email invitation item.
  """
  attr :invitation, :map, required: true
  attr :is_owner, :boolean, default: false
  attr :myself, :any, required: true

  def invitation_item(assigns) do
    ~H"""
    <div
      id={"invitation-#{@invitation.id}"}
      class="flex items-center gap-3 p-2 rounded-lg bg-base-200/50"
    >
      <div class="w-8 h-8 shrink-0 rounded-full bg-base-300 text-base-content/50 flex items-center justify-center">
        <.icon name="lucide-mail" class="w-4 h-4" />
      </div>
      <div class="flex-1 min-w-0">
        <div class="text-sm truncate text-base-content/70">
          {@invitation.email}
        </div>
        <div class="flex flex-wrap items-center gap-1 text-xs text-base-content/50">
          <span class="badge badge-xs badge-ghost whitespace-nowrap">
            {gettext("pending invite")}
          </span>
          <span class={"badge badge-xs #{role_badge_class(@invitation.role)}"}>
            {role_label(@invitation.role)}
          </span>
        </div>
      </div>
      <button
        :if={@is_owner}
        class="btn btn-ghost btn-xs text-error"
        phx-click="cancel_invitation"
        phx-value-id={@invitation.id}
        phx-target={@myself}
      >
        <.icon name="lucide-x" class="w-4 h-4" />
      </button>
    </div>
    """
  end

  @doc """
  Renders an invite link item with copy and delete buttons.
  """
  attr :link, :map, required: true
  attr :myself, :any, required: true

  def invite_link_item(assigns) do
    ~H"""
    <div class="p-2 bg-base-200 rounded-lg text-sm">
      <div class="flex items-center gap-2 mb-1">
        <code class="text-xs flex-1 truncate">
          {build_public_url(@link.token)}
        </code>
        <button
          class="btn btn-ghost btn-xs"
          phx-click={Phoenix.LiveView.JS.dispatch("phx:copy", to: "#link-#{@link.id}")}
        >
          <.icon name="lucide-clipboard" class="w-3 h-3" />
        </button>
        <input
          type="hidden"
          id={"link-#{@link.id}"}
          value={build_public_url(@link.token)}
        />
      </div>
      <div class="flex items-center justify-between text-xs text-base-content/60">
        <span>
          {role_label(@link.role)}
          <%= if @link.password_hash do %>
            <span class="badge badge-xs">{gettext("password")}</span>
          <% end %>
        </span>
        <button
          class="text-error hover:underline"
          phx-click="delete_link"
          phx-value-id={@link.id}
          phx-target={@myself}
        >
          {gettext("Delete")}
        </button>
      </div>
    </div>
    """
  end

  # Helper functions

  def display_name(%Ash.NotLoaded{}), do: gettext("Unknown")

  def display_name(user) when is_struct(user) do
    cond do
      is_binary(user.display_name) and user.display_name != "" ->
        user.display_name

      not is_nil(user.email) ->
        to_string(user.email)

      true ->
        gettext("Unknown")
    end
  end

  def display_name(_), do: gettext("Unknown")

  def role_label(:owner), do: gettext("Owner")
  def role_label(:member), do: gettext("Member")
  def role_label(:observer), do: gettext("Observer")

  def role_badge_class(:owner), do: "badge-primary"
  def role_badge_class(:member), do: "badge-secondary"
  def role_badge_class(:observer), do: "badge-ghost"

  def build_public_url(token) do
    Magus.Endpoint.url() <> "/chat/join/#{token}"
  end
end
