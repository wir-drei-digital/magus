defmodule MagusWeb.Workbench.Layout.TabBar do
  @moduledoc """
  Horizontal tab bar. Emits `activate_tab`, `close_tab`, and `new_tab` events
  to the parent LiveView. Label and icon come from LabelResolver.

  The tab label and the close affordance are sibling buttons inside a
  non-interactive container div — nesting a close <button> inside the
  activate <button> would be invalid HTML and would dispatch both phx-click
  handlers via DOM bubbling (activating a tab that was just closed).
  """
  use MagusWeb, :live_component

  alias Phoenix.LiveView.JS
  alias MagusWeb.Workbench.Tab.LabelResolver

  @impl true
  def render(assigns) do
    # When a detail view (settings, jobs, search, etc.) is occupying the primary
    # slot, the active tab is not actually visible — suppress the active styling
    # so the tab strip doesn't claim a tab is currently rendered.
    assigns = assign_new(assigns, :detail_view, fn -> nil end)
    active_id = if assigns.detail_view, do: nil, else: assigns.active_tab_id
    assigns = assign(assigns, :visible_active_tab_id, active_id)

    ~H"""
    <div class="flex items-center border-b border-wb-border min-w-0">
      <div
        class="wb-tab-strip flex-1 min-w-0 flex items-center gap-1 px-2 py-1.5 overflow-x-auto"
        role="tablist"
        phx-hook=".VerticalWheelToHorizontal"
        id="wb-tab-strip"
      >
        <script :type={Phoenix.LiveView.ColocatedHook} name=".VerticalWheelToHorizontal">
          export default {
            mounted() {
              this.onWheel = (e) => {
                // If user is scrolling primarily vertically and there's room to
                // scroll horizontally, redirect the delta. Skip if the user is
                // also moving horizontally (trackpad two-finger swipe) — let
                // the browser handle that natively.
                if (e.deltaY === 0) return;
                if (Math.abs(e.deltaX) > Math.abs(e.deltaY)) return;
                const canScroll = this.el.scrollWidth > this.el.clientWidth;
                if (!canScroll) return;
                e.preventDefault();
                this.el.scrollLeft += e.deltaY;
              };
              this.el.addEventListener("wheel", this.onWheel, { passive: false });
            },
            destroyed() {
              this.el.removeEventListener("wheel", this.onWheel);
            }
          }
        </script>
        <div
          :for={tab <- @tabs}
          role="tab"
          data-tab-role="tab"
          data-tab-id={tab["id"]}
          aria-selected={tab["id"] == @visible_active_tab_id}
          class={[
            "group relative flex items-center gap-1 pl-3 pr-1 py-1 text-sm rounded-md transition-colors",
            "basis-[180px] min-w-[96px] max-w-[220px]",
            if(tab["id"] == @visible_active_tab_id,
              do: "bg-wb-hover text-wb-text",
              else:
                "bg-transparent text-wb-text-muted hover:bg-wb-hover/60 hover:text-wb-text-secondary"
            )
          ]}
        >
          <button
            type="button"
            data-activate-tab={tab["id"]}
            phx-click="activate_tab"
            phx-value-tab_id={tab["id"]}
            class="flex-1 min-w-0 inline-flex items-center gap-2"
          >
            <.icon
              name={LabelResolver.icon_for(tab)}
              class="w-3.5 h-3.5 shrink-0 text-wb-text-muted"
            />
            <span class="truncate">{LabelResolver.label_for(tab)}</span>
          </button>
          <button
            type="button"
            data-close-tab={tab["id"]}
            phx-click={JS.push("close_tab", value: %{tab_id: tab["id"]}) |> JS.focus()}
            class="shrink-0 opacity-50 hover:opacity-100 hover:bg-wb-hover rounded w-5 h-5 flex items-center justify-center text-base"
            aria-label="Close tab"
          >
            ×
          </button>
        </div>
      </div>

      <%!-- <button
        type="button"
        phx-click="new_tab"
        data-new-tab
        class="shrink-0 mx-1 mb-0.5 w-7 h-7 flex items-center justify-center text-base text-wb-text-muted hover:text-wb-text hover:bg-wb-hover rounded-md transition-colors"
        aria-label="New tab"
      >
        +
      </button> --%>
    </div>
    """
  end
end
