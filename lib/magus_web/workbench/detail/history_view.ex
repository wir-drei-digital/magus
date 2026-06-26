defmodule MagusWeb.Workbench.Detail.HistoryView do
  @moduledoc """
  Conversation history detail view: paginated list of all conversations plus a
  trash tab with restore / permanently delete / empty trash actions. The
  History/Trash switch lives in the workbench detail-nav sidebar (see
  `Detail.Builder.build_history/2`); this LiveView owns the list, search, and
  pagination state for whichever tab is active.
  """
  use MagusWeb, :live_view

  on_mount({MagusWeb.LiveUserAuth, :restore_locale})

  require Ash.Query

  @per_page 30

  @impl true
  def mount(_params, %{"user_id" => user_id} = session, socket) do
    user = Magus.Accounts.get_user!(user_id, authorize?: false)
    tab = parse_tab(session["tab"])

    socket =
      socket
      |> assign(:current_user, user)
      |> assign(:workspace_id, session["workspace_id"])
      |> assign(:tab, tab)
      |> assign(:search_query, "")
      |> assign(:page, 1)
      |> assign(:per_page, @per_page)
      |> load_conversations()

    {:ok, socket}
  end

  defp parse_tab("trash"), do: :trash
  defp parse_tab(_), do: :history

  defp load_conversations(socket) do
    case socket.assigns.tab do
      :history -> load_history(socket)
      :trash -> load_trash(socket)
    end
  end

  defp load_history(socket) do
    %{
      search_query: query,
      page: page,
      per_page: per_page,
      current_user: user,
      workspace_id: workspace_id
    } = socket.assigns

    offset = (page - 1) * per_page

    {conversations, total_count} =
      if query == "" do
        load_all_conversations(user, workspace_id, offset, per_page)
      else
        unified_search(user, workspace_id, query, offset, per_page)
      end

    total_pages = ceil(total_count / per_page)

    socket
    |> assign(:conversations, conversations)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, max(total_pages, 1))
  end

  defp load_trash(socket) do
    %{page: page, per_page: per_page, current_user: user, workspace_id: workspace_id} =
      socket.assigns

    offset = (page - 1) * per_page

    base_query =
      Magus.Chat.Conversation
      |> Ash.Query.for_read(:trashed, %{}, actor: user)
      |> filter_by_workspace(workspace_id)

    total_count = Ash.count!(base_query, actor: user)

    conversations =
      base_query
      |> Ash.Query.offset(offset)
      |> Ash.Query.limit(per_page)
      |> Ash.Query.load([:message_count])
      |> Ash.read!(actor: user)

    total_pages = ceil(total_count / per_page)

    socket
    |> assign(:conversations, conversations)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, max(total_pages, 1))
  end

  defp load_all_conversations(user, workspace_id, offset, per_page) do
    base_query =
      Magus.Chat.Conversation
      |> Ash.Query.for_read(:my_conversations, %{}, actor: user)
      |> filter_by_workspace(workspace_id)
      |> Ash.Query.sort(last_message_at: :desc_nils_last)

    total_count = Ash.count!(base_query, actor: user)

    conversations =
      base_query
      |> Ash.Query.offset(offset)
      |> Ash.Query.limit(per_page)
      |> Ash.Query.load([:message_count, :last_message_at])
      |> Ash.read!(actor: user)

    {conversations, total_count}
  end

  # The `m0` alias targets the messages table directly: both messages and
  # conversations have a `search_vector` column and Ash's policy join makes an
  # unqualified reference ambiguous (Postgres 42702).
  defp unified_search(user, workspace_id, query, offset, per_page) do
    message_conv_ids =
      Magus.Chat.Message
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(
        fragment(
          "m0.search_vector @@ plainto_tsquery('simple', ?) OR similarity(m0.text, ?) > 0.3",
          ^query,
          ^query
        )
      )
      |> Ash.Query.filter(conversation.user_id == ^user.id)
      |> filter_messages_by_workspace(workspace_id)
      |> Ash.read!(actor: user)
      |> Enum.map(& &1.conversation_id)
      |> Enum.uniq()

    base_query =
      Magus.Chat.Conversation
      |> Ash.Query.for_read(:my_conversations, %{}, actor: user)
      |> filter_by_workspace(workspace_id)
      |> Ash.Query.filter(
        fragment(
          "search_vector @@ plainto_tsquery('simple', ?) OR similarity(title, ?) > 0.3",
          ^query,
          ^query
        ) or id in ^message_conv_ids
      )
      |> Ash.Query.sort(last_message_at: :desc_nils_last)

    total_count = Ash.count!(base_query, actor: user)

    conversations =
      base_query
      |> Ash.Query.offset(offset)
      |> Ash.Query.limit(per_page)
      |> Ash.Query.load([:message_count, :last_message_at])
      |> Ash.read!(actor: user)

    {conversations, total_count}
  end

  # Scope the conversation list to the active workspace. nil workspace means
  # "personal" (only conversations without a workspace_id).
  defp filter_by_workspace(query, nil),
    do: Ash.Query.filter(query, is_nil(workspace_id))

  defp filter_by_workspace(query, workspace_id),
    do: Ash.Query.filter(query, workspace_id == ^workspace_id)

  # Same scope rule applied to the message search join, so search results stay
  # within the active workspace.
  defp filter_messages_by_workspace(query, nil),
    do: Ash.Query.filter(query, is_nil(conversation.workspace_id))

  defp filter_messages_by_workspace(query, workspace_id),
    do: Ash.Query.filter(query, conversation.workspace_id == ^workspace_id)

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:page, 1)
     |> load_conversations()}
  end

  def handle_event("page", %{"page" => page}, socket) do
    page = String.to_integer(page)
    page = max(1, min(page, socket.assigns.total_pages))

    {:noreply,
     socket
     |> assign(:page, page)
     |> load_conversations()}
  end

  def handle_event("restore", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case fetch_trashed(id, user) do
      nil ->
        {:noreply,
         socket |> put_flash(:error, gettext("Conversation not found")) |> load_conversations()}

      conversation ->
        Magus.Chat.restore_conversation!(conversation, actor: user)

        {:noreply,
         socket |> put_flash(:info, gettext("Conversation restored")) |> load_conversations()}
    end
  end

  def handle_event("permanently_delete", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case fetch_trashed(id, user) do
      nil ->
        {:noreply,
         socket |> put_flash(:error, gettext("Conversation not found")) |> load_conversations()}

      conversation ->
        Magus.Chat.delete_full_conversation!(conversation, actor: user)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Conversation permanently deleted"))
         |> load_conversations()}
    end
  end

  # Iterate one-by-one rather than bulk_destroy because DeleteFullConversation's
  # before_action triggers DeleteFile which calls decrement_storage_usage in an
  # after_action hook — Ash code interfaces break inside bulk stream contexts.
  # Scope the wipe to the active workspace context so a user in workspace A
  # can't accidentally hard-delete trashed conversations from workspace B or
  # from their personal space.
  def handle_event("empty_trash", _params, socket) do
    %{current_user: user, workspace_id: workspace_id} = socket.assigns

    failed =
      Magus.Chat.Conversation
      |> Ash.Query.for_read(:trashed, %{}, actor: user)
      |> filter_by_workspace(workspace_id)
      |> Ash.read!(actor: user)
      |> Enum.count(fn conv ->
        case Magus.Chat.delete_full_conversation(conv, actor: user) do
          :ok -> false
          {:error, _} -> true
        end
      end)

    flash_action =
      if failed > 0,
        do:
          &put_flash(
            &1,
            :error,
            gettext("Failed to delete %{count} conversations", count: failed)
          ),
        else: &put_flash(&1, :info, gettext("Trash emptied"))

    {:noreply, socket |> flash_action.() |> load_conversations()}
  end

  defp fetch_trashed(id, user) do
    Magus.Chat.Conversation
    |> Ash.Query.for_read(:trashed, %{}, actor: user)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(actor: user)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full overflow-y-auto" data-detail-view="history">
      <div class="container mx-auto max-w-5xl py-6 px-4">
        <div class="mb-6">
          <h1 class="text-2xl font-bold text-wb-text mb-1">
            {if @tab == :trash,
              do: gettext("Trash"),
              else: gettext("Conversation History")}
          </h1>
          <p class="text-wb-text-muted text-sm">
            {if @tab == :trash,
              do:
                gettext(
                  "Deleted conversations auto-purge after 30 days. Restore or permanently delete."
                ),
              else: gettext("Browse and search your past conversations")}
          </p>
        </div>

        <form :if={@tab == :history} phx-change="search" phx-submit="search" class="relative mb-4">
          <div class="relative">
            <.icon
              name="lucide-search"
              class="absolute left-4 top-1/2 -translate-y-1/2 w-5 h-5 text-wb-text-muted"
            />
            <input
              type="text"
              name="query"
              value={@search_query}
              placeholder={gettext("Search conversations and messages...")}
              aria-label={gettext("Search conversations")}
              phx-debounce="300"
              class="w-full pl-12 pr-4 py-3 bg-wb-surface border border-wb-border rounded-xl text-wb-text placeholder:text-wb-text-muted focus:outline-none focus:ring-2 focus:ring-primary/50 focus:border-primary"
            />
          </div>
        </form>

        <div class="flex items-center justify-between mb-3">
          <p class="text-sm text-wb-text-muted">
            {ngettext("1 conversation", "%{count} conversations", @total_count)}
          </p>
          <button
            :if={@tab == :trash and @total_count > 0}
            class="btn btn-error btn-sm"
            phx-click="empty_trash"
            data-confirm={
              gettext("Permanently delete all conversations in trash? This cannot be undone.")
            }
          >
            <.icon name="lucide-trash-2" class="w-4 h-4" />
            {gettext("Empty trash")}
          </button>
        </div>

        <div class="min-h-[300px]">
          <.empty_state :if={@conversations == []} search_query={@search_query} tab={@tab} />
          <.history_list
            :if={@conversations != [] and @tab == :history}
            conversations={@conversations}
          />
          <.trash_list :if={@conversations != [] and @tab == :trash} conversations={@conversations} />
        </div>

        <div
          :if={@total_pages > 1}
          class="flex items-center justify-between pt-4 mt-4 border-t border-wb-border"
        >
          <div class="text-sm text-wb-text-muted">
            {gettext("Showing %{from} to %{to} of %{total}",
              from: (@page - 1) * @per_page + 1,
              to: min(@page * @per_page, @total_count),
              total: @total_count
            )}
          </div>
          <div class="join">
            <button
              class="join-item btn btn-sm"
              disabled={@page == 1}
              phx-click="page"
              phx-value-page={@page - 1}
            >
              <.icon name="lucide-chevron-left" class="w-4 h-4" />
            </button>
            <%= for p <- pagination_range(@page, @total_pages) do %>
              <%= if p == :ellipsis do %>
                <span class="join-item btn btn-sm btn-disabled">...</span>
              <% else %>
                <button
                  class={"join-item btn btn-sm #{if p == @page, do: "btn-primary"}"}
                  phx-click="page"
                  phx-value-page={p}
                >
                  {p}
                </button>
              <% end %>
            <% end %>
            <button
              class="join-item btn btn-sm"
              disabled={@page == @total_pages}
              phx-click="page"
              phx-value-page={@page + 1}
            >
              <.icon name="lucide-chevron-right" class="w-4 h-4" />
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-12 text-wb-text-muted">
      <%= if @tab == :trash do %>
        <.icon name="lucide-trash-2" class="w-12 h-12 mb-4 opacity-50" />
        <p class="text-lg mb-1">{gettext("Trash is empty")}</p>
        <p class="text-sm">
          {gettext("Deleted conversations appear here for 30 days before being permanently removed")}
        </p>
      <% else %>
        <.icon name="lucide-messages-square" class="w-12 h-12 mb-4 opacity-50" />
        <%= if @search_query == "" do %>
          <p class="text-lg mb-1">{gettext("No conversations yet")}</p>
          <p class="text-sm">{gettext("Start a new chat to begin")}</p>
        <% else %>
          <p class="text-lg mb-1">
            {gettext("No results found for \"%{query}\"", query: @search_query)}
          </p>
          <p class="text-sm">{gettext("Try different keywords or check your spelling")}</p>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp history_list(assigns) do
    ~H"""
    <div class="grid gap-3">
      <.list_card
        :for={conv <- @conversations}
        navigate={~p"/chat/#{conv.id}"}
        icon="lucide-messages-square"
      >
        <:title>{conv.title || gettext("Untitled conversation")}</:title>
        <:meta>
          <span class="flex items-center gap-1">
            <.icon name="lucide-calendar" class="w-3.5 h-3.5" />
            {format_date(last_activity_at(conv))}
          </span>
          <span class="flex items-center gap-1">
            <.icon name="lucide-message-square" class="w-3.5 h-3.5" />
            {ngettext("1 message", "%{count} messages", conv.message_count || 0)}
          </span>
        </:meta>
      </.list_card>
    </div>
    """
  end

  defp trash_list(assigns) do
    ~H"""
    <div class="grid gap-3">
      <div
        :for={conv <- @conversations}
        class="bg-wb-surface border border-wb-border rounded-xl p-4 flex items-center justify-between"
      >
        <div class="min-w-0 flex-1">
          <h3 class="font-medium text-wb-text truncate">
            {conv.title || gettext("Untitled conversation")}
          </h3>
          <div class="flex items-center gap-3 mt-1 text-sm text-wb-text-muted">
            <span class="flex items-center gap-1">
              <.icon name="lucide-trash-2" class="w-3.5 h-3.5" />
              {gettext("Deleted %{date}", date: format_date(conv.deleted_at))}
            </span>
            <span class="flex items-center gap-1">
              <.icon name="lucide-message-square" class="w-3.5 h-3.5" />
              {ngettext("1 message", "%{count} messages", conv.message_count || 0)}
            </span>
            <span class="text-warning text-xs">
              {gettext("Auto-deletes %{date}", date: format_date(purge_date(conv.deleted_at)))}
            </span>
          </div>
        </div>
        <div class="flex items-center gap-2 ml-4">
          <button
            class="btn btn-ghost btn-sm"
            phx-click="restore"
            phx-value-id={conv.id}
            title={gettext("Restore conversation")}
          >
            <.icon name="lucide-undo-2" class="w-4 h-4" />
            {gettext("Restore")}
          </button>
          <button
            class="btn btn-ghost btn-sm text-error"
            phx-click="permanently_delete"
            phx-value-id={conv.id}
            data-confirm={gettext("Permanently delete this conversation? This cannot be undone.")}
            title={gettext("Delete permanently")}
          >
            <.icon name="lucide-x" class="w-4 h-4" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y")
  end

  # Conversations are ordered by most recent message; show that date, falling
  # back to updated_at for conversations that have no messages yet.
  defp last_activity_at(%{last_message_at: %DateTime{} = dt}), do: dt
  defp last_activity_at(%{updated_at: dt}), do: dt

  defp purge_date(deleted_at) do
    DateTime.add(deleted_at, 30, :day)
  end

  defp pagination_range(_current, total) when total <= 7 do
    Enum.to_list(1..total)
  end

  defp pagination_range(current, total) do
    cond do
      current <= 3 ->
        [1, 2, 3, 4, :ellipsis, total]

      current >= total - 2 ->
        [1, :ellipsis, total - 3, total - 2, total - 1, total]

      true ->
        [1, :ellipsis, current - 1, current, current + 1, :ellipsis, total]
    end
  end
end
