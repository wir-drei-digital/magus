defmodule MagusWeb.SearchLive do
  @moduledoc """
  Unified search interface for searching across messages, conversations,
  prompts, and memory resources.
  """
  use MagusWeb, :live_view

  on_mount {MagusWeb.LiveUserAuth, :live_user_required}

  alias Magus.Search

  @impl true
  def mount(_params, _session, socket) do
    {:ok, init_assigns(socket, "", %{}, socket.assigns.current_user)}
  end

  @doc """
  Public init hook used by SearchView (workbench detail view).
  """
  def init_assigns(socket, query, _filters, _user) do
    assign(socket,
      query: query,
      results: [],
      loading: false,
      search_ref: nil,
      selected_types: [:message, :conversation, :prompt, :resource, :chunk],
      type_counts: %{},
      page_title: gettext("Search")
    )
  end

  @impl true
  def handle_params(%{"q" => query}, _uri, socket)
      when is_binary(query) and byte_size(query) >= 2 do
    send(self(), {:perform_search, query})
    {:noreply, assign(socket, query: query, loading: true)}
  end

  def handle_params(%{"q" => query}, _uri, socket) when is_binary(query) do
    # Query too short, just show it in the input
    {:noreply, assign(socket, query: query)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  # ============================================
  # Events
  # ============================================

  @impl true
  def handle_event("search", %{"query" => query}, socket) when byte_size(query) < 2 do
    {:noreply,
     socket
     |> assign(query: query, results: [], loading: false)
     |> push_patch(to: ~p"/search", replace: true)}
  end

  def handle_event("search", %{"query" => query}, socket) do
    # Cancel any pending search
    if socket.assigns.search_ref do
      Process.cancel_timer(socket.assigns.search_ref)
    end

    # Debounce: wait 150ms before searching
    ref = Process.send_after(self(), {:perform_search, query}, 150)

    {:noreply,
     socket
     |> assign(query: query, loading: true, search_ref: ref)
     |> push_patch(to: ~p"/search?q=#{query}", replace: true)}
  end

  def handle_event("toggle_type", %{"type" => type}, socket) do
    type = String.to_existing_atom(type)
    selected = socket.assigns.selected_types

    updated =
      if type in selected and length(selected) > 1 do
        List.delete(selected, type)
      else
        if type in selected, do: selected, else: [type | selected]
      end

    socket = assign(socket, selected_types: updated)

    # Re-run search if we have a query
    if socket.assigns.query != "" and byte_size(socket.assigns.query) >= 2 do
      send(self(), {:perform_search, socket.assigns.query})
      {:noreply, assign(socket, loading: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear", _, socket) do
    {:noreply, assign(socket, query: "", results: [], loading: false)}
  end

  # ============================================
  # Info handlers
  # ============================================

  @impl true
  def handle_info({:perform_search, query}, socket) do
    actor = socket.assigns.current_user

    {:ok, results} =
      Search.search(query,
        types: socket.assigns.selected_types,
        limit: 30,
        actor: actor
      )

    type_counts = Enum.frequencies_by(results, & &1.type)

    {:noreply,
     socket
     |> assign(results: results, loading: false, search_ref: nil, type_counts: type_counts)}
  end

  # ============================================
  # Render
  # ============================================

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      show_sidebar={false}
      bg_class="bg-spectral"
    >
      <:notification_bell>
        <.live_component
          module={MagusWeb.NotificationBellComponent}
          id="notification-bell"
          current_user={@current_user}
          unread_count={@unread_count}
        />
      </:notification_bell>

      <div class="min-h-full">
        <div class="max-w-4xl mx-auto p-4 md:p-8">
          <div class="mb-8">
            <h1 class="text-2xl font-bold text-base-content mb-2">{gettext("Search")}</h1>
            <p class="text-base-content/60">
              {gettext("Search across messages, conversations, prompts, and files")}
            </p>
          </div>
          {render_search_results(assigns)}
        </div>
      </div>
    </Layouts.app>
    """
  end

  @doc """
  Renders the search form and results body (no Layouts.app wrapper).
  Used by SearchView (workbench detail view).
  """
  def render_search_results(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- Search Input --%>
      <form phx-change="search" phx-submit="search" class="relative">
        <div class="relative">
          <.icon
            name="lucide-search"
            class="absolute left-4 top-1/2 -translate-y-1/2 w-5 h-5 text-base-content/40"
          />
          <input
            type="text"
            name="query"
            value={@query}
            placeholder={gettext("Search messages, conversations, prompts, files...")}
            aria-label={gettext("Search")}
            phx-debounce="150"
            autofocus
            class="w-full pl-12 pr-12 py-4 bg-base-100 border border-base-300 rounded-xl text-base-content placeholder:text-base-content/40 focus:outline-none focus:ring-2 focus:ring-primary/50 focus:border-primary shadow-sm"
          />
          <button
            :if={@query != ""}
            type="button"
            phx-click="clear"
            class="absolute right-4 top-1/2 -translate-y-1/2 p-1 hover:bg-base-300 rounded-lg"
          >
            <.icon name="lucide-x" class="w-5 h-5 text-base-content/40" />
          </button>
        </div>
      </form>

      <%!-- Type Filters --%>
      <div class="flex flex-wrap gap-2">
        <.filter_button
          :for={type <- [:message, :conversation, :prompt, :resource, :chunk]}
          type={type}
          selected={@selected_types}
          count={Map.get(@type_counts, type, 0)}
        />
      </div>

      <%!-- Results --%>
      <div class="min-h-[300px]">
        <%= cond do %>
          <% @loading -> %>
            <.loading_state />
          <% @query == "" -> %>
            <.empty_state />
          <% @results == [] -> %>
            <.no_results query={@query} />
          <% true -> %>
            <.result_list results={@results} />
        <% end %>
      </div>

      <%!-- Keyboard hints --%>
      <div class="mt-8 pt-4 border-t border-base-300 flex items-center gap-4 text-sm text-base-content/50">
        <span class="flex items-center gap-1.5">
          <kbd class="px-2 py-1 bg-base-300 rounded text-xs font-mono">/</kbd>
          {gettext("Focus search")}
        </span>
        <span class="flex items-center gap-1.5">
          <kbd class="px-2 py-1 bg-base-300 rounded text-xs font-mono">Esc</kbd>
          {gettext("Clear")}
        </span>
      </div>
    </div>
    """
  end

  # ============================================
  # Components
  # ============================================

  defp filter_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_type"
      phx-value-type={@type}
      class={[
        "flex items-center gap-2 px-3 py-1.5 rounded-lg text-sm font-medium transition-colors",
        if(@type in @selected,
          do: "bg-primary text-primary-content",
          else: "bg-base-200 text-base-content/60 hover:bg-base-300"
        )
      ]}
    >
      <.type_icon type={@type} />
      <span>{type_label(@type)}</span>
      <span
        :if={@count > 0}
        class={[
          "px-1.5 py-0.5 text-xs rounded-full",
          if(@type in @selected,
            do: "bg-primary-content/20 text-primary-content",
            else: "bg-base-300 text-base-content/60"
          )
        ]}
      >
        {@count}
      </span>
    </button>
    """
  end

  defp type_icon(%{type: :message} = assigns),
    do: ~H|<.icon name="lucide-message-square" class="w-4 h-4" />|

  defp type_icon(%{type: :conversation} = assigns),
    do: ~H|<.icon name="lucide-messages-square" class="w-4 h-4" />|

  defp type_icon(%{type: :prompt} = assigns),
    do: ~H|<.icon name="lucide-puzzle" class="w-4 h-4" />|

  defp type_icon(%{type: :resource} = assigns),
    do: ~H|<.icon name="lucide-file" class="w-4 h-4" />|

  defp type_icon(%{type: :chunk} = assigns),
    do: ~H|<.icon name="lucide-file-text" class="w-4 h-4" />|

  defp type_label(:message), do: gettext("Messages")
  defp type_label(:conversation), do: gettext("Conversations")
  defp type_label(:prompt), do: gettext("Prompts")
  defp type_label(:resource), do: gettext("Files")
  defp type_label(:chunk), do: gettext("File Content")

  defp type_icon_name(:message), do: "lucide-message-square"
  defp type_icon_name(:conversation), do: "lucide-messages-square"
  defp type_icon_name(:prompt), do: "lucide-puzzle"
  defp type_icon_name(:resource), do: "lucide-file"
  defp type_icon_name(:chunk), do: "lucide-file-text"

  defp loading_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-12 text-base-content/50">
      <span class="loading loading-spinner loading-lg mb-4"></span>
      <span>{gettext("Searching...")}</span>
    </div>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-12 text-base-content/50">
      <.icon name="lucide-search" class="w-12 h-12 mb-4 opacity-50" />
      <p class="text-lg">{gettext("Start typing to search across all your content")}</p>
    </div>
    """
  end

  defp no_results(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-12 text-base-content/50">
      <.icon name="lucide-frown" class="w-12 h-12 mb-4 opacity-50" />
      <p class="text-lg mb-2">{gettext("No results found for \"%{query}\"", query: @query)}</p>
      <p class="text-sm">{gettext("Try different keywords or check your spelling")}</p>
    </div>
    """
  end

  defp result_list(assigns) do
    ~H"""
    <div class="grid gap-4">
      <.list_card
        :for={result <- @results}
        navigate={result_url(result)}
        icon={type_icon_name(result.type)}
      >
        <:title>{result.title}</:title>
        <:badge>
          <span class="text-xs px-2 py-0.5 bg-base-200 rounded-full text-base-content/60 shrink-0">
            {type_label(result.type)}
          </span>
        </:badge>
        <:subtitle>{Phoenix.HTML.raw(result.snippet)}</:subtitle>
        <:meta>
          <span :if={result.metadata[:created_at]}>{format_date(result.metadata.created_at)}</span>
        </:meta>
      </.list_card>
    </div>
    """
  end

  defp result_url(%{type: :message, id: id, metadata: %{conversation_id: conv_id}}) do
    ~p"/chat/#{conv_id}?highlight=#{id}"
  end

  defp result_url(%{type: :conversation, id: id}) do
    ~p"/chat/#{id}"
  end

  defp result_url(%{type: :prompt, id: id}) do
    ~p"/prompts/#{id}"
  end

  defp result_url(%{type: :resource, id: id}) do
    ~p"/chat?resource=#{id}"
  end

  defp result_url(%{type: :chunk, metadata: %{file_id: file_id}}) do
    ~p"/chat?resource=#{file_id}"
  end

  defp format_date(nil), do: ""

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y")
  end
end
