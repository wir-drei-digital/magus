defmodule MagusWeb.Workbench.Layout.ResourceTree.SectionHeader do
  @moduledoc """
  Shared section header + empty state function components used by
  ResourceTree and AgentsModeNav for visual consistency.
  """
  use MagusWeb, :html

  attr :label, :string, required: true
  attr :badge, :string, default: nil
  attr :collapsible?, :boolean, default: false
  attr :collapsed?, :boolean, default: false
  attr :icon, :string, default: nil
  attr :on_toggle, :any, default: nil
  attr :target, :any, default: nil

  @doc "Renders a section header with consistent chrome across mode navs."
  def section_header(assigns) do
    ~H"""
    <%= if @collapsible? do %>
      <button
        type="button"
        phx-click={@on_toggle}
        phx-target={@target}
        class="px-4 py-2 flex items-center gap-2 text-[11px] font-semibold uppercase tracking-wider text-wb-text-dim hover:text-wb-text"
      >
        <.icon
          name="lucide-chevron-right"
          class={["w-3.5 h-3.5 transition-transform", !@collapsed? && "rotate-90"]}
        />
        <.icon :if={@icon} name={@icon} class="w-3.5 h-3.5" />
        <span>{@label}</span>
        <span :if={@badge} class="text-wb-text-dim">({@badge})</span>
      </button>
    <% else %>
      <header class="px-4 py-2 flex items-center gap-2 text-[11px] font-semibold uppercase tracking-wider text-wb-text-dim">
        <.icon :if={@icon} name={@icon} class="w-3.5 h-3.5" />
        <span>{@label}</span>
        <span :if={@badge} class="text-wb-text-dim">({@badge})</span>
      </header>
    <% end %>
    """
  end

  attr :message, :string, required: true

  @doc "Renders a one-line muted empty-state placeholder."
  def empty_state(assigns) do
    ~H"""
    <li class="px-3 py-1 text-xs text-wb-text-dim list-none">{@message}</li>
    """
  end
end
