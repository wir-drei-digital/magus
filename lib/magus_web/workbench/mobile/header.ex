defmodule MagusWeb.Workbench.Mobile.Header do
  @moduledoc """
  Mobile floating pill chrome.

  Renders pills positioned absolute over the workbench so the active view
  uses the entire viewport. The hamburger pill at top-left toggles the
  drawer; the optional `:pill` slot (tabs pill) docks at top-right.

  Companion takeover renders nothing — the companion view supplies its
  own back arrow.
  """
  use MagusWeb, :html

  attr :variant, :atom, values: [:default, :companion], default: :default
  slot :pill

  def header(%{variant: :companion} = assigns), do: ~H""

  def header(assigns) do
    ~H"""
    <div
      id="mobile-header"
      data-mobile-header
      data-mobile-header-variant={@variant}
      class="pointer-events-none absolute inset-x-0 top-0 z-30 flex items-start justify-between p-2"
    >
      <button
        type="button"
        data-mobile-hamburger
        phx-click="toggle_drawer"
        class="pointer-events-auto h-9 w-9 flex items-center justify-center rounded-full bg-wb-bg/80 backdrop-blur-sm border border-wb-border shadow-sm text-wb-text hover:bg-wb-bg"
        aria-label="Open navigation"
      >
        <.icon name="lucide-menu" class="w-5 h-5" />
      </button>

      <div data-mobile-header-pill-slot class="pointer-events-auto">
        {render_slot(@pill)}
      </div>
    </div>
    """
  end
end
