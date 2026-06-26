defmodule MagusWeb.ChatLive.Components.Library.CollapsibleBox do
  @moduledoc """
  Collapsible card component for the Library sidebar sections.

  Renders as an expanded card with content when open, or as a
  compact pill button when collapsed.
  """
  use Phoenix.Component

  import MagusWeb.CoreComponents

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :icon, :string, required: true
  attr :expanded, :boolean, required: true
  attr :myself, :any, required: true
  attr :toggle_event, :string, required: true
  attr :always_expanded, :boolean, default: false
  attr :floating_mode, :boolean, default: false
  attr :action_icon, :string, default: nil
  attr :action_event, :any, default: nil
  attr :action_title, :string, default: nil

  attr :action_label, :string,
    default: nil,
    doc: "Short visible label (chromeless mode). Defaults to action_title."

  attr :secondary_action_icon, :string, default: nil
  attr :secondary_action_event, :string, default: nil
  attr :secondary_action_title, :string, default: nil

  attr :secondary_action_label, :string,
    default: nil,
    doc: "Short visible label (chromeless mode). Defaults to secondary_action_title."

  attr :badge, :integer, default: nil
  attr :description, :string, default: nil

  attr :chromeless, :boolean,
    default: false,
    doc:
      "Render without an outer card border or section icon. Used when the section is the sole occupant of an already-bordered surface (e.g. the More popover)."

  slot :inner_block, required: true

  def collapsible_box(%{chromeless: true} = assigns) do
    ~H"""
    <div id={@id} class="h-full flex flex-col min-h-0">
      <div class="flex items-center justify-between px-3 py-2 shrink-0 border-b border-base-300/60">
        <div class="flex items-center gap-2 min-w-0">
          <span class="font-medium text-sm truncate">{@title}</span>
          <span :if={@badge && @badge > 0} class="text-xs opacity-50">{@badge}</span>
        </div>
        <div class="flex items-center gap-1 shrink-0">
          <button
            :if={@secondary_action_icon}
            type="button"
            class="wb-pill-btn"
            phx-click={@secondary_action_event}
            phx-target={@myself}
            title={@secondary_action_title}
          >
            <.icon name={@secondary_action_icon} class="w-4 h-4" />
            <span>{@secondary_action_label || @secondary_action_title}</span>
          </button>
          <button
            :if={@action_icon}
            type="button"
            class="wb-pill-btn"
            phx-click={@action_event}
            phx-target={if is_binary(@action_event), do: @myself}
            title={@action_title}
          >
            <.icon name={@action_icon} class="w-4 h-4" />
            <span>{@action_label || @action_title}</span>
          </button>
        </div>
      </div>
      <div class="flex-1 min-h-0 overflow-y-auto p-3">
        <p :if={@description} class="text-xs text-base-content/50 mb-2">{@description}</p>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  def collapsible_box(assigns) do
    ~H"""
    <%= if @expanded do %>
      <%!-- Expanded: Full Card --%>
      <div id={@id} class={["sidebar-card", @floating_mode && "sidebar-card-floating shadow-md/20!"]}>
        <div
          class={[
            "flex items-center justify-between px-3 py-2.5 bg-base-100 border-b border-base-300 transition-colors hover:bg-primary/5",
            !@always_expanded && "cursor-pointer"
          ]}
          phx-click={!@always_expanded && @toggle_event}
          phx-target={@myself}
        >
          <div class="flex items-center gap-2">
            <.icon name={@icon} class="w-5 h-5 text-primary/70" />
            <span class="font-medium text-sm">{@title}</span>
            <span :if={@badge && @badge > 0} class="text-xs opacity-50">{@badge}</span>
          </div>
          <div class="flex items-center gap-1">
            <button
              :if={@secondary_action_icon}
              type="button"
              class="icon-btn cursor-pointer"
              phx-click={@secondary_action_event}
              phx-target={@myself}
              title={@secondary_action_title}
            >
              <.icon name={@secondary_action_icon} class="w-5 h-5" />
            </button>
            <button
              :if={@action_icon}
              type="button"
              class="icon-btn cursor-pointer"
              phx-click={@action_event}
              phx-target={if is_binary(@action_event), do: @myself}
              title={@action_title}
            >
              <.icon name={@action_icon} class="w-5 h-5" />
            </button>
            <.icon :if={!@always_expanded} name="lucide-chevron-up" class="w-5 h-5 opacity-50" />
          </div>
        </div>
        <div class="sidebar-card-content">
          <p :if={@description} class="text-xs text-base-content/50 py-1 mb-2">{@description}</p>

          {render_slot(@inner_block)}
        </div>
      </div>
    <% else %>
      <%!-- Collapsed: Pill Button, Right Aligned --%>
      <div id={@id} class="flex justify-end">
        <button
          type="button"
          class="sidebar-card-pill cursor-pointer"
          phx-click={@toggle_event}
          phx-target={@myself}
          title={@title}
        >
          <.icon name={@icon} class="w-5 h-5 text-primary" />
          <span class="font-normal dark:text-white">{@title}</span>
        </button>
      </div>
    <% end %>
    """
  end
end
