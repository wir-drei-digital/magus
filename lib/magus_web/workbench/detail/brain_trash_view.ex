defmodule MagusWeb.Workbench.Detail.BrainTrashView do
  @moduledoc """
  Detail view at `/brain/trash`: paginated list of soft-deleted brain
  pages (deletion roots only) for the active workspace. Mirrors the
  conversation `HistoryView` trash tab's UX — restore / permanently
  delete / empty trash.
  """
  use MagusWeb, :live_view

  on_mount({MagusWeb.LiveUserAuth, :restore_locale})

  require Ash.Query

  @per_page 30

  @impl true
  def mount(_params, %{"user_id" => user_id} = session, socket) do
    user = Magus.Accounts.get_user!(user_id, authorize?: false)

    {:ok,
     socket
     |> assign(:current_user, user)
     |> assign(:workspace_id, session["workspace_id"])
     |> assign(:page, 1)
     |> assign(:per_page, @per_page)
     |> load_pages()}
  end

  defp load_pages(socket) do
    %{
      page: page,
      per_page: per_page,
      current_user: user,
      workspace_id: workspace_id
    } = socket.assigns

    offset = (page - 1) * per_page

    base_query =
      Magus.Brain.Page
      |> Ash.Query.for_read(:trashed, %{workspace_id: workspace_id}, actor: user)

    total_count = Ash.count!(base_query, actor: user)

    pages =
      base_query
      |> Ash.Query.offset(offset)
      |> Ash.Query.limit(per_page)
      |> Ash.read!(actor: user)

    total_pages = max(ceil(total_count / per_page), 1)

    socket
    |> assign(:pages, pages)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, total_pages)
  end

  @impl true
  def handle_event("page", %{"page" => page}, socket) do
    page = String.to_integer(page)
    page = max(1, min(page, socket.assigns.total_pages))
    {:noreply, socket |> assign(:page, page) |> load_pages()}
  end

  def handle_event("restore", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case fetch_trashed(id, user, socket.assigns.workspace_id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Page not found"))}

      page ->
        case Magus.Brain.restore_page(page, actor: user) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Page restored"))
             |> load_pages()}

          {:error, error} ->
            {:noreply,
             socket
             |> put_flash(:error, restore_error_message(error))
             |> load_pages()}
        end
    end
  end

  def handle_event("permanently_delete", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case fetch_trashed(id, user, socket.assigns.workspace_id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Page not found"))}

      page ->
        Magus.Brain.destroy_page!(page, actor: user)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Page permanently deleted"))
         |> load_pages()}
    end
  end

  def handle_event("empty_trash", _params, socket) do
    %{current_user: user, workspace_id: workspace_id} = socket.assigns

    pages =
      Magus.Brain.Page
      |> Ash.Query.for_read(:trashed, %{workspace_id: workspace_id}, actor: user)
      |> Ash.read!(actor: user)

    failed =
      Enum.count(pages, fn page ->
        case Magus.Brain.destroy_page(page, actor: user) do
          :ok -> false
          {:ok, _} -> false
          {:error, _} -> true
        end
      end)

    flash_action =
      if failed > 0,
        do: &put_flash(&1, :error, gettext("Failed to delete %{count} pages", count: failed)),
        else: &put_flash(&1, :info, gettext("Trash emptied"))

    {:noreply, socket |> flash_action.() |> load_pages()}
  end

  defp restore_error_message(%Ash.Error.Invalid{errors: errors}) do
    cond do
      Enum.any?(errors, &match?(%{field: :parent_page_id}, &1)) ->
        gettext("Restore the parent page first.")

      Enum.any?(errors, &match?(%{field: :deleted_at}, &1)) ->
        gettext("Page is not in the trash.")

      true ->
        gettext("Could not restore page.")
    end
  end

  defp restore_error_message(_), do: gettext("Could not restore page.")

  defp fetch_trashed(id, user, workspace_id) do
    Magus.Brain.Page
    |> Ash.Query.for_read(:trashed, %{workspace_id: workspace_id}, actor: user)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(actor: user)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full overflow-y-auto" data-detail-view="brain-trash">
      <div class="container mx-auto max-w-5xl py-6 px-4">
        <div class="mb-6">
          <h1 class="text-2xl font-bold text-wb-text mb-1">{gettext("Brain Trash")}</h1>
          <p class="text-wb-text-muted text-sm">
            {gettext("Deleted brain pages auto-purge after 30 days. Restore or permanently delete.")}
          </p>
        </div>

        <div class="flex items-center justify-between mb-3">
          <p class="text-sm text-wb-text-muted">
            {ngettext("1 page", "%{count} pages", @total_count)}
          </p>
          <button
            :if={@total_count > 0}
            class="btn btn-error btn-sm"
            phx-click="empty_trash"
            data-confirm={gettext("Permanently delete all pages in trash? This cannot be undone.")}
          >
            <.icon name="lucide-trash-2" class="w-4 h-4" />
            {gettext("Empty trash")}
          </button>
        </div>

        <div class="min-h-[300px]">
          <.empty_state :if={@pages == []} />
          <.trash_list :if={@pages != []} pages={@pages} />
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

  defp empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-12 text-wb-text-muted">
      <.icon name="lucide-trash-2" class="w-12 h-12 mb-4 opacity-50" />
      <p class="text-lg mb-1">{gettext("Trash is empty")}</p>
      <p class="text-sm">
        {gettext("Deleted brain pages appear here for 30 days before being permanently removed")}
      </p>
    </div>
    """
  end

  defp trash_list(assigns) do
    ~H"""
    <div class="grid gap-3">
      <div
        :for={page <- @pages}
        class="bg-wb-surface border border-wb-border rounded-xl p-4 flex items-center justify-between"
      >
        <div class="min-w-0 flex-1">
          <h3 class="font-medium text-wb-text truncate">
            {page.title || gettext("Untitled page")}
          </h3>
          <div class="flex items-center gap-3 mt-1 text-sm text-wb-text-muted">
            <span class="flex items-center gap-1">
              <.icon name="lucide-brain" class="w-3.5 h-3.5" />
              {page.brain && page.brain.title}
            </span>
            <span class="flex items-center gap-1">
              <.icon name="lucide-trash-2" class="w-3.5 h-3.5" />
              {gettext("Deleted %{date}", date: format_date(page.deleted_at))}
            </span>
            <span class="text-warning text-xs">
              {gettext("Auto-deletes %{date}", date: format_date(purge_date(page.deleted_at)))}
            </span>
          </div>
        </div>
        <div class="flex items-center gap-2 ml-4">
          <button
            class="btn btn-ghost btn-sm"
            phx-click="restore"
            phx-value-id={page.id}
            title={gettext("Restore page")}
          >
            <.icon name="lucide-undo-2" class="w-4 h-4" />
            {gettext("Restore")}
          </button>
          <button
            class="btn btn-ghost btn-sm text-error"
            phx-click="permanently_delete"
            phx-value-id={page.id}
            data-confirm={gettext("Permanently delete this page? This cannot be undone.")}
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

  defp purge_date(deleted_at) do
    DateTime.add(deleted_at, 30, :day)
  end
end
