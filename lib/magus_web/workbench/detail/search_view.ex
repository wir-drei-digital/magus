defmodule MagusWeb.Workbench.Detail.SearchView do
  @moduledoc """
  Search detail view. Receives ?q=... and renders grouped results.
  """
  use MagusWeb, :live_view

  on_mount({MagusWeb.LiveUserAuth, :restore_locale})

  @impl true
  def mount(_params, %{"user_id" => user_id} = session, socket) do
    user = Magus.Accounts.get_user!(user_id, authorize?: false)
    query = Map.get(session, "q", "")
    type = Map.get(session, "type", "all")

    socket =
      socket
      |> assign(:current_user, user)
      |> assign(:query, query)
      |> assign(:type_filter, type)
      |> MagusWeb.SearchLive.init_assigns(query, %{type: type}, user)

    # Trigger an immediate search when mounted with a non-trivial query.
    # SearchLive normally relies on handle_params to fire the search, but
    # handle_params is unreachable in nested LiveViews (detail views). Sending
    # the message here mirrors exactly what handle_params does in SearchLive.
    if byte_size(query) >= 2 do
      send(self(), {:perform_search, query})
    end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full overflow-y-auto" data-detail-view="search">
      <div class="container mx-auto max-w-5xl py-6 px-4">
        {MagusWeb.SearchLive.render_search_results(assigns)}
      </div>
    </div>
    """
  end

  @impl true
  def handle_event(event, params, socket),
    do: MagusWeb.SearchLive.handle_event(event, params, socket)

  @impl true
  def handle_info(msg, socket),
    do: MagusWeb.SearchLive.handle_info(msg, socket)
end
