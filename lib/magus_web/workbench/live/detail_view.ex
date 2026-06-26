defmodule MagusWeb.Workbench.Live.DetailView do
  @moduledoc """
  Renders the detail-view region (settings, jobs, search, workspace pages)
  inside the workbench shell. Either delegates to a child LiveView via
  live_render or shows a placeholder for unhandled detail types.
  """

  use Phoenix.Component

  attr :detail_view, :map, required: true
  attr :socket, :any, required: true

  def render(%{detail_view: %{live_module: module, live_session: session, live_id: id}} = assigns) do
    # Child live_renders mount in their own process and lose the Gettext locale
    # resolved by the parent WorkbenchLive. Propagate it through the session so
    # the child can restore it on connect (MagusWeb.LiveUserAuth :restore_locale),
    # otherwise the page flickers from the user's language to the default locale.
    session = Map.put_new(session, "locale", Gettext.get_locale(MagusWeb.Gettext))
    assigns = assign(assigns, module: module, session: session, live_id: id)

    ~H"""
    {live_render(@socket, @module,
      id: @live_id,
      session: @session
    )}
    """
  end

  def render(%{detail_view: %{type: type}} = assigns) do
    assigns = assign(assigns, :detail_type, type)

    ~H"""
    <div
      class="h-full flex items-center justify-center text-wb-text-muted"
      data-detail-view={@detail_type}
    >
      <p>Detail view "{@detail_type}" not implemented yet.</p>
    </div>
    """
  end
end
