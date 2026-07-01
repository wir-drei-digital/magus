defmodule MagusWeb.Admin.UsersLive do
  @moduledoc """
  Admin view for managing users.
  """
  use MagusWeb, :live_view

  alias MagusWeb.Layouts

  @per_page 20

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Users")
      |> assign(:current_path, "/admin/users")
      |> assign(:search_query, "")
      |> assign(:sort_by, :inserted_at)
      |> assign(:sort_order, :desc)
      |> assign(:page, 1)
      |> assign(:per_page, @per_page)
      |> assign(:filter, "all")
      |> load_users()

    {:ok, socket}
  end

  defp load_users(socket) do
    require Ash.Query

    %{
      search_query: query,
      sort_by: sort_by,
      sort_order: sort_order,
      page: page,
      per_page: per_page,
      filter: filter
    } = socket.assigns

    offset = (page - 1) * per_page

    base_query =
      Magus.Accounts.User
      |> Ash.Query.for_read(:read)

    # Apply search filter
    base_query =
      if query != "" do
        Ash.Query.filter(base_query, contains(email, ^query) or contains(display_name, ^query))
      else
        base_query
      end

    # Apply the selected filter
    base_query =
      case filter do
        "admins" -> Ash.Query.filter(base_query, is_admin == true)
        "non_admins" -> Ash.Query.filter(base_query, is_admin == false)
        "demo" -> Ash.Query.filter(base_query, test_account == true)
        _ -> base_query
      end

    # Get total count
    total_count = Ash.count!(base_query, authorize?: false)

    # Apply sorting and pagination
    users =
      base_query
      |> Ash.Query.sort([{sort_by, sort_order}])
      |> Ash.Query.offset(offset)
      |> Ash.Query.limit(per_page)
      |> Ash.read!(authorize?: false)

    # Load user stats in a single query (avoid N+1)
    user_ids = Enum.map(users, & &1.id)
    stats_by_user = get_bulk_user_stats(user_ids)
    subscriptions_by_user = get_bulk_subscriptions(user_ids)

    users_with_stats =
      Enum.map(users, fn user ->
        stats =
          Map.get(stats_by_user, user.id, %{
            message_count: 0,
            total_cost: Decimal.new(0),
            last_active: nil
          })

        subscription = Map.get(subscriptions_by_user, user.id)

        Map.merge(user, %{
          message_count: stats.message_count,
          total_cost: stats.total_cost,
          last_active: stats.last_active,
          subscription_plan: subscription && subscription.name
        })
      end)

    total_pages = ceil(total_count / per_page)

    socket
    |> assign(:users, users_with_stats)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, max(total_pages, 1))
  end

  defp get_bulk_user_stats(user_ids) when user_ids == [], do: %{}

  defp get_bulk_user_stats(user_ids) do
    require Ash.Query

    usages =
      Magus.Usage.MessageUsage
      |> Ash.Query.filter(user_id in ^user_ids)
      |> Ash.read!(authorize?: false)

    # Group by user_id and aggregate stats
    Enum.group_by(usages, & &1.user_id)
    |> Enum.map(fn {user_id, user_usages} ->
      message_count = length(user_usages)

      total_cost =
        Enum.reduce(user_usages, Decimal.new(0), fn u, acc ->
          Decimal.add(acc, u.total_cost || Decimal.new(0))
        end)

      last_active =
        user_usages
        |> Enum.map(& &1.inserted_at)
        |> Enum.max(DateTime, fn -> nil end)

      {user_id, %{message_count: message_count, total_cost: total_cost, last_active: last_active}}
    end)
    |> Map.new()
  end

  defp get_bulk_subscriptions(user_ids) when user_ids == [], do: %{}

  defp get_bulk_subscriptions(user_ids) do
    require Ash.Query

    Magus.Usage.Account
    |> Ash.Query.filter(user_id in ^user_ids)
    |> Ash.Query.load(:usage_plan)
    |> Ash.read!(authorize?: false)
    |> Map.new(fn sub ->
      {sub.user_id, %{name: sub.usage_plan.name}}
    end)
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    socket =
      socket
      |> assign(:search_query, query)
      |> assign(:page, 1)
      |> load_users()

    {:noreply, socket}
  end

  @impl true
  def handle_event("sort", %{"field" => field}, socket) do
    field_atom = String.to_existing_atom(field)

    {sort_by, sort_order} =
      if socket.assigns.sort_by == field_atom do
        # Toggle order
        new_order = if socket.assigns.sort_order == :asc, do: :desc, else: :asc
        {field_atom, new_order}
      else
        {field_atom, :asc}
      end

    socket =
      socket
      |> assign(:sort_by, sort_by)
      |> assign(:sort_order, sort_order)
      |> load_users()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", %{"value" => value}, socket) do
    socket =
      socket
      |> assign(:filter, value)
      |> assign(:page, 1)
      |> load_users()

    {:noreply, socket}
  end

  @impl true
  def handle_event("page", %{"page" => page}, socket) do
    page = String.to_integer(page)

    socket =
      socket
      |> assign(:page, page)
      |> load_users()

    {:noreply, socket}
  end

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
              Manage registered users ({@total_count} total)
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
                  value={@search_query}
                  placeholder="Search by email or name..."
                  class="input input-bordered input-sm w-full pl-9"
                  phx-debounce="300"
                />
              </div>
            </form>

            <select
              class="select select-bordered select-sm"
              phx-change="filter"
              name="value"
            >
              <option value="all" selected={@filter == "all"}>All Users</option>
              <option value="admins" selected={@filter == "admins"}>Admins Only</option>
              <option value="non_admins" selected={@filter == "non_admins"}>Non-Admins</option>
              <option value="demo" selected={@filter == "demo"}>Demo Accounts</option>
            </select>
          </div>
        </div>

        <%!-- Users Table --%>
        <div class="card bg-base-200 border border-base-300 overflow-hidden">
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr class="bg-base-300/50">
                  <th
                    class="cursor-pointer hover:bg-base-300"
                    phx-click="sort"
                    phx-value-field="email"
                  >
                    <div class="flex items-center gap-1">
                      Email <.sort_indicator field={:email} current={@sort_by} order={@sort_order} />
                    </div>
                  </th>
                  <th
                    class="cursor-pointer hover:bg-base-300"
                    phx-click="sort"
                    phx-value-field="display_name"
                  >
                    <div class="flex items-center gap-1">
                      Name
                      <.sort_indicator field={:display_name} current={@sort_by} order={@sort_order} />
                    </div>
                  </th>
                  <th
                    class="cursor-pointer hover:bg-base-300"
                    phx-click="sort"
                    phx-value-field="inserted_at"
                  >
                    <div class="flex items-center gap-1">
                      Joined
                      <.sort_indicator field={:inserted_at} current={@sort_by} order={@sort_order} />
                    </div>
                  </th>
                  <th>Subscription</th>
                  <th class="text-right">Messages</th>
                  <th class="text-right">Cost</th>
                  <th>Last Active</th>
                  <th class="text-center">Admin</th>
                </tr>
              </thead>
              <tbody>
                <%= if @users == [] do %>
                  <tr>
                    <td colspan="9" class="text-center py-8 text-base-content/50">
                      No users found
                    </td>
                  </tr>
                <% else %>
                  <%= for user <- @users do %>
                    <tr
                      class="hover:bg-base-300/30 cursor-pointer"
                      phx-click={JS.navigate(~p"/admin/users/#{user.id}")}
                    >
                      <td>
                        <div class="flex items-center gap-2">
                          <div class="w-8 h-8 rounded-full bg-gradient-to-br from-primary/20 to-secondary/20 flex items-center justify-center border border-base-300">
                            <span class="text-sm font-medium text-base-content">
                              {user.email |> to_string() |> String.first() |> String.upcase()}
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
                        <%= if user.subscription_plan do %>
                          <span class="badge badge-outline badge-sm">{user.subscription_plan}</span>
                        <% else %>
                          <span class="text-base-content/30 text-sm">None</span>
                        <% end %>
                      </td>
                      <td class="text-right font-mono text-sm">{user.message_count}</td>
                      <td class="text-right font-mono text-sm">{format_cost(user.total_cost)}</td>
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
                  <% end %>
                <% end %>
              </tbody>
            </table>
          </div>

          <%!-- Pagination --%>
          <%= if @total_pages > 1 do %>
            <div class="flex items-center justify-between px-4 py-3 border-t border-base-300">
              <div class="text-sm text-base-content/60">
                Showing {(@page - 1) * @per_page + 1} to {min(@page * @per_page, @total_count)} of {@total_count}
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
                      class={"join-item btn btn-sm #{if p == @page, do: "btn-active"}"}
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

  attr :field, :atom, required: true
  attr :current, :atom, required: true
  attr :order, :atom, required: true

  defp sort_indicator(assigns) do
    ~H"""
    <%= if @field == @current do %>
      <%= if @order == :asc do %>
        <.icon name="lucide-chevron-up" class="w-3 h-3" />
      <% else %>
        <.icon name="lucide-chevron-down" class="w-3 h-3" />
      <% end %>
    <% else %>
      <.icon name="lucide-chevrons-up-down" class="w-3 h-3 opacity-30" />
    <% end %>
    """
  end

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y")
  end

  defp format_last_active(nil), do: "-"

  defp format_last_active(datetime) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, datetime, :second)

    cond do
      diff_seconds < 60 -> "Just now"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86400 -> "#{div(diff_seconds, 3600)}h ago"
      diff_seconds < 604_800 -> "#{div(diff_seconds, 86400)}d ago"
      true -> Calendar.strftime(datetime, "%b %d")
    end
  end

  defp format_cost(decimal) do
    "$" <> (decimal |> Decimal.round(2) |> Decimal.to_string())
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
