defmodule MagusWeb.Workbench.Layout.DetailNav do
  @moduledoc """
  Sub-nav rendered in the workbench nav-pane while a detail view is active
  (settings, workspace, jobs, search). Each detail view registers a list of
  sections; this component renders them as a vertical list with active-state
  highlighting.
  """
  use MagusWeb, :live_component

  attr :detail_view, :map, required: true
  attr :current_user, :map, required: true

  @impl true
  def render(assigns) do
    sections = assigns.detail_view[:sections] || []
    title = assigns.detail_view[:title] || ""
    assigns = assign(assigns, sections: sections, title: title)

    ~H"""
    <nav class="flex flex-col h-full overflow-y-auto px-3 py-4" aria-label={@title}>
      <h2 :if={@title != ""} class="px-2 mb-2 text-xs uppercase tracking-wide text-wb-text-muted">
        {@title}
      </h2>
      <ul class="flex flex-col gap-0.5">
        <li :for={section <- @sections}>
          <.link
            patch={section.href}
            data-detail-section={section.key}
            class={[
              "flex items-center gap-2 px-2 py-1.5 rounded-md text-sm transition-colors",
              if(section.active?,
                do: "bg-wb-surface-2 text-wb-text",
                else: "text-wb-text-muted hover:bg-wb-hover"
              )
            ]}
          >
            <.icon :if={section[:icon]} name={section.icon} class="w-4 h-4" />
            <span>{section.label}</span>
          </.link>
        </li>
      </ul>
    </nav>
    """
  end
end
