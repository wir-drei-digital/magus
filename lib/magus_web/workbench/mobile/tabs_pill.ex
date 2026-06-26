defmodule MagusWeb.Workbench.Mobile.TabsPill do
  @moduledoc """
  Mobile-only tabs pill for the workbench header. Renders a compact pill
  showing the active tab + total count; tapping opens a popover with all
  open tabs and a "+ New chat" footer. Stateless — open/close lives in
  the parent LV's assigns and is passed via `:open?`.

  Emits parent events:
    - `toggle_tabs_pill` (no payload) — parent flips open?
    - `activate_tab` with `tab_id`
    - `close_tab` with `tab_id`
    - `new_tab`
  """
  use MagusWeb, :live_component

  alias MagusWeb.Workbench.Tab.LabelResolver

  attr :id, :string, required: true
  attr :tabs, :list, required: true
  attr :active_tab_id, :any, required: true
  attr :open?, :boolean, required: true

  @impl true
  def render(%{tabs: []} = assigns) do
    ~H"""
    <div data-tabs-pill-empty></div>
    """
  end

  def render(assigns) do
    active = Enum.find(assigns.tabs, &(&1["id"] == assigns.active_tab_id)) || hd(assigns.tabs)
    assigns = assign(assigns, :active_tab, active)

    ~H"""
    <div class="relative" data-tabs-pill>
      <button
        type="button"
        data-tabs-pill-trigger
        phx-click="toggle_tabs_pill"
        aria-label={"Open tabs (#{length(@tabs)})"}
        class="relative h-9 w-9 flex items-center justify-center rounded-full bg-wb-bg/80 backdrop-blur-sm border border-wb-border shadow-sm text-wb-text hover:bg-wb-bg transition-colors"
      >
        <.icon name={LabelResolver.icon_for(@active_tab)} class="w-4 h-4" />
        <span
          :if={length(@tabs) > 1}
          class="absolute -top-1 -right-1 min-w-[1.125rem] h-[1.125rem] px-1 flex items-center justify-center rounded-full bg-wb-accent-soft text-wb-text text-[10px] font-medium leading-none border border-wb-bg"
        >
          {length(@tabs)}
        </span>
      </button>

      <div
        :if={@open?}
        data-tabs-pill-popover
        class="absolute right-0 top-full mt-1 w-[min(280px,calc(100vw-1rem))] max-h-[60vh] overflow-y-auto bg-wb-surface border border-wb-border rounded-lg shadow-xl z-40"
      >
        <div class="px-3 py-1.5 text-[10px] font-semibold uppercase tracking-wider text-wb-text-muted">
          Open tabs
        </div>
        <ul>
          <li :for={tab <- @tabs} class="px-1">
            <div class="flex items-center gap-1">
              <button
                type="button"
                data-pill-tab={tab["id"]}
                data-pill-tab-active={tab["id"] == @active_tab_id && tab["id"]}
                phx-click="activate_tab"
                phx-value-tab_id={tab["id"]}
                class={[
                  "flex-1 flex items-center gap-2 px-2 py-1.5 rounded text-sm text-left",
                  if(tab["id"] == @active_tab_id,
                    do: "bg-wb-hover text-wb-text",
                    else: "text-wb-text-secondary hover:bg-wb-hover"
                  )
                ]}
              >
                <.icon name={LabelResolver.icon_for(tab)} class="w-3.5 h-3.5 shrink-0" />
                <span class="truncate">{LabelResolver.label_for(tab)}</span>
              </button>
              <button
                type="button"
                data-pill-close-tab={tab["id"]}
                phx-click="close_tab"
                phx-value-tab_id={tab["id"]}
                class="shrink-0 w-6 h-6 flex items-center justify-center rounded text-wb-text-muted hover:text-wb-text hover:bg-wb-hover"
                aria-label="Close tab"
              >
                ×
              </button>
            </div>
          </li>
        </ul>
        <div class="border-t border-wb-border mt-1 pt-1 px-1 pb-1">
          <button
            type="button"
            data-pill-new-chat
            phx-click="new_tab"
            class="w-full flex items-center gap-2 px-2 py-1.5 text-sm text-wb-accent-soft hover:bg-wb-hover rounded"
          >
            <.icon name="lucide-plus" class="w-3.5 h-3.5" />
            <span>New chat</span>
          </button>
        </div>
      </div>
    </div>
    """
  end
end
