defmodule MagusWeb.Admin.UsersLive do
  @moduledoc """
  Admin view for managing users.

  Search / filter / sort / page state lives in the URL query string (like the
  admin Models index), so views are shareable and the back button works. Every
  column — including the usage rollups (messages, cost, last active) and plan —
  sorts in SQL via `AdminStats.list_users/1`, so ordering is correct across
  pages. Data loads with `assign_async`.
  """
  use MagusWeb, :live_view

  alias Magus.Usage.AdminStats
  alias MagusWeb.Formatters
  alias MagusWeb.Layouts
  alias Phoenix.LiveView.AsyncResult

  @per_page 20
  @filters ~w(all admins non_admins demo)
  @default_sort "inserted_at"
  @default_dir "desc"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Users")
      |> assign(:current_path, "/admin/users")
      |> assign(:per_page, @per_page)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    list = %{
      search: to_string(params["q"] || ""),
      filter: normalize(params["filter"], @filters, "all"),
      sort: normalize(params["sort"], AdminStats.user_sorts(), @default_sort),
      dir: normalize(params["dir"], ~w(asc desc), @default_dir),
      page: parse_page(params["page"])
    }

    {:noreply, socket |> assign(:list, list) |> load_users()}
  end

  defp load_users(socket) do
    %{search: search, filter: filter, sort: sort, dir: dir, page: page} = socket.assigns.list

    if connected?(socket) do
      assign_async(socket, :page_data, fn ->
        %{users: users, total_count: total_count} =
          AdminStats.list_users(
            search: search,
            filter: filter,
            sort: sort,
            dir: dir,
            page: page,
            per_page: @per_page
          )

        {:ok,
         %{
           page_data: %{
             users: users,
             total_count: total_count,
             total_pages: max(ceil(total_count / @per_page), 1)
           }
         }}
      end)
    else
      assign(socket, :page_data, AsyncResult.loading())
    end
  end

  # Form events only translate into the URL; handle_params does the loading.

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    patch_list(socket, %{search: query, page: 1})
  end

  @impl true
  def handle_event("filter", %{"value" => value}, socket) do
    patch_list(socket, %{filter: value, page: 1})
  end

  @impl true
  def handle_event("sort", %{"field" => field}, socket) do
    list = socket.assigns.list

    dir =
      cond do
        list.sort != field -> "asc"
        list.dir == "asc" -> "desc"
        true -> "asc"
      end

    patch_list(socket, %{sort: field, dir: dir, page: 1})
  end

  defp patch_list(socket, changes) do
    list = Map.merge(socket.assigns.list, changes)
    {:noreply, push_patch(socket, to: list_path(list))}
  end

  defp list_path(list) do
    query =
      %{
        "q" => list.search,
        "filter" => list.filter,
        "sort" => list.sort,
        "dir" => list.dir,
        "page" => to_string(list.page)
      }
      |> Enum.reject(fn {k, v} -> default_param?(k, v) end)
      |> Enum.sort()

    ~p"/admin/users?#{query}"
  end

  # Bare /admin/users represents the default view: no search, all users,
  # newest first, first page.
  defp default_param?(_k, v) when v in [nil, ""], do: true
  defp default_param?("filter", "all"), do: true
  defp default_param?("sort", @default_sort), do: true
  defp default_param?("dir", @default_dir), do: true
  defp default_param?("page", "1"), do: true
  defp default_param?(_k, _v), do: false

  defp normalize(value, allowed, default) do
    if is_binary(value) and value in allowed, do: value, else: default
  end

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n >= 1 -> n
      _ -> 1
    end
  end

  defp parse_page(_), do: 1

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="space-y-6">
        <%!-- Header --%>
        <div class="flex flex-col md:flex-row md:items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-bold text-base-content">Users</h1>
            <p class="text-base-content/60 text-sm mt-1">
              <%= if @page_data.ok? do %>
                Manage registered users ({@page_data.result.total_count} total)
              <% else %>
                Manage registered users
              <% end %>
            </p>
          </div>

          <%!-- Search and Filters --%>
          <div class="flex flex-wrap items-center gap-3">
            <form phx-change="search" phx-submit="search" class="flex-1 min-w-[200px]">
              <div class="relative">
                <.icon
                  name="lucide-search"
                  class="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-base-content/40"
                />
                <input
                  type="text"
                  name="query"
                  value={@list.search}
                  placeholder="Search by email or name..."
                  class="input input-bordered input-sm w-full pl-9"
                  phx-debounce="300"
                />
              </div>
            </form>

            <form phx-change="filter">
              <select class="select select-bordered select-sm" name="value">
                <option value="all" selected={@list.filter == "all"}>All Users</option>
                <option value="admins" selected={@list.filter == "admins"}>Admins Only</option>
                <option value="non_admins" selected={@list.filter == "non_admins"}>
                  Non-Admins
                </option>
                <option value="demo" selected={@list.filter == "demo"}>Demo Accounts</option>
              </select>
            </form>
          </div>
        </div>

        <%!-- Users Table --%>
        <div class="card bg-base-200 border border-base-300 overflow-hidden">
          <div class="overflow-x-auto">
            <table class="table table-sm" data-test-users-table>
              <thead>
                <tr class="bg-base-300/50">
                  <.sort_header label="Email" field="email" list={@list} />
                  <.sort_header label="Name" field="display_name" list={@list} />
                  <.sort_header label="Joined" field="inserted_at" list={@list} />
                  <.sort_header label="Subscription" field="plan" list={@list} />
                  <.sort_header label="Messages" field="message_count" list={@list} align="right" />
                  <.sort_header label="Cost" field="total_cost" list={@list} align="right" />
                  <.sort_header label="Last Active" field="last_active" list={@list} />
                  <th class="text-center">Admin</th>
                </tr>
              </thead>
              <tbody>
                <.async_result :let={page_data} assign={@page_data}>
                  <:loading>
                    <tr>
                      <td colspan="8" class="text-center py-12">
                        <span class="loading loading-spinner"></span>
                      </td>
                    </tr>
                  </:loading>
                  <:failed>
                    <tr>
                      <td colspan="8" class="text-center py-8 text-error">
                        Failed to load users.
                      </td>
                    </tr>
                  </:failed>
                  <tr :if={page_data.users == []}>
                    <td colspan="8" class="text-center py-8 text-base-content/50">
                      No users found
                    </td>
                  </tr>
                  <tr
                    :for={user <- page_data.users}
                    class="hover:bg-base-300/30 cursor-pointer"
                    data-test-user-row={user.id}
                    phx-click={JS.navigate(~p"/admin/users/#{user.id}")}
                  >
                    <td>
                      <div class="flex items-center gap-2">
                        <div class="w-8 h-8 rounded-full bg-gradient-to-br from-primary/20 to-secondary/20 flex items-center justify-center border border-base-300">
                          <span class="text-sm font-medium text-base-content">
                            {user.email |> String.first() |> String.upcase()}
                          </span>
                        </div>
                        <span class="text-sm">{user.email}</span>
                        <span
                          :if={user.test_account}
                          class="badge badge-info badge-sm"
                          title="Demo account"
                        >
                          demo
                        </span>
                      </div>
                    </td>
                    <td class="text-base-content/70">{user.display_name || "-"}</td>
                    <td class="text-base-content/70 text-sm">
                      {format_date(user.inserted_at)}
                    </td>
                    <td>
                      <%= if user.plan_name do %>
                        <span class="badge badge-outline badge-sm">{user.plan_name}</span>
                      <% else %>
                        <span class="text-base-content/30 text-sm">None</span>
                      <% end %>
                    </td>
                    <td class="text-right font-mono text-sm">{user.message_count}</td>
                    <td class="text-right font-mono text-sm">
                      {Formatters.format_cost(user.total_cost, 2)}
                    </td>
                    <td class="text-base-content/70 text-sm">
                      {format_last_active(user.last_active)}
                    </td>
                    <td class="text-center">
                      <%= if user.is_admin do %>
                        <span class="badge badge-primary badge-sm">Admin</span>
                      <% else %>
                        <span class="text-base-content/30">-</span>
                      <% end %>
                    </td>
                  </tr>
                </.async_result>
              </tbody>
            </table>
          </div>

          <%!-- Pagination --%>
          <%= if @page_data.ok? && @page_data.result.total_pages > 1 do %>
            <% page_data = @page_data.result %>
            <div class="flex items-center justify-between px-4 py-3 border-t border-base-300">
              <div class="text-sm text-base-content/60">
                Showing {(@list.page - 1) * @per_page + 1} to {min(
                  @list.page * @per_page,
                  page_data.total_count
                )} of {page_data.total_count}
              </div>
              <div class="join">
                <.link
                  patch={list_path(%{@list | page: @list.page - 1})}
                  class={["join-item btn btn-sm", @list.page == 1 && "btn-disabled"]}
                >
                  <.icon name="lucide-chevron-left" class="w-4 h-4" />
                </.link>
                <%= for p <- pagination_range(@list.page, page_data.total_pages) do %>
                  <%= if p == :ellipsis do %>
                    <span class="join-item btn btn-sm btn-disabled">...</span>
                  <% else %>
                    <.link
                      patch={list_path(%{@list | page: p})}
                      class={["join-item btn btn-sm", p == @list.page && "btn-active"]}
                    >
                      {p}
                    </.link>
                  <% end %>
                <% end %>
                <.link
                  patch={list_path(%{@list | page: @list.page + 1})}
                  class={[
                    "join-item btn btn-sm",
                    @list.page == page_data.total_pages && "btn-disabled"
                  ]}
                >
                  <.icon name="lucide-chevron-right" class="w-4 h-4" />
                </.link>
              </div>
            </div>
          <% end %>
        </div>

        <%!-- Actions --%>
        <div class="flex justify-end">
          <.link navigate={~p"/admin/users/test-accounts/new"} class="btn btn-primary btn-sm">
            <.icon name="lucide-user-plus" class="w-4 h-4" /> Add Demo Users
          </.link>
        </div>
      </div>
    </Layouts.admin>
    """
  end

  attr :label, :string, required: true
  attr :field, :string, required: true
  attr :list, :map, required: true
  attr :align, :string, default: "left"

  defp sort_header(assigns) do
    ~H"""
    <th
      class={["cursor-pointer hover:bg-base-300", @align == "right" && "text-right"]}
      phx-click="sort"
      phx-value-field={@field}
      data-test-sort={@field}
    >
      <div class={["flex items-center gap-1", @align == "right" && "justify-end"]}>
        {@label}
        <%= if @list.sort == @field do %>
          <.icon
            name={if @list.dir == "asc", do: "lucide-chevron-up", else: "lucide-chevron-down"}
            class="w-3 h-3"
          />
        <% else %>
          <.icon name="lucide-chevrons-up-down" class="w-3 h-3 opacity-30" />
        <% end %>
      </div>
    </th>
    """
  end

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y")
  end

  defp format_last_active(nil), do: "-"

  defp format_last_active(datetime) do
    diff_seconds = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff_seconds < 60 -> "Just now"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86400 -> "#{div(diff_seconds, 3600)}h ago"
      diff_seconds < 604_800 -> "#{div(diff_seconds, 86400)}d ago"
      true -> Calendar.strftime(datetime, "%b %d")
    end
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
