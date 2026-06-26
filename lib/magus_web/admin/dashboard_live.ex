defmodule MagusWeb.Admin.DashboardLive do
  @moduledoc """
  Admin dashboard with key metrics and analytics.
  """
  use MagusWeb, :live_view

  alias MagusWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Admin Dashboard")
      |> assign(:current_path, "/admin")
      |> load_metrics()

    {:ok, socket}
  end

  defp load_metrics(socket) do
    socket
    |> assign(:total_users, count_users())
    |> assign(:active_users, count_active_users())
    |> assign(:total_messages, count_messages())
    |> assign(:total_cost, calculate_total_cost())
    |> assign(:popular_models, get_popular_models())
    |> assign(:cost_by_model, get_cost_by_model())
  end

  defp count_users do
    require Ash.Query

    Magus.Accounts.User
    |> Ash.Query.for_read(:read)
    |> Ash.count!(authorize?: false)
  end

  defp count_active_users do
    require Ash.Query

    fifteen_minutes_ago = DateTime.add(DateTime.utc_now(), -15, :minute)

    # Count users who have message_usage records in the last 15 minutes
    Magus.Usage.MessageUsage
    |> Ash.Query.filter(inserted_at >= ^fifteen_minutes_ago)
    |> Ash.Query.distinct(:user_id)
    |> Ash.count!(authorize?: false)
  end

  defp count_messages do
    require Ash.Query

    Magus.Chat.Message
    |> Ash.Query.for_read(:read)
    |> Ash.count!(authorize?: false)
  end

  defp calculate_total_cost do
    require Ash.Query

    Magus.Usage.MessageUsage
    |> Ash.Query.for_read(:read)
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(Decimal.new(0), fn usage, acc ->
      Decimal.add(acc, usage.total_cost || Decimal.new(0))
    end)
  end

  defp get_popular_models do
    require Ash.Query

    Magus.Usage.MessageUsage
    |> Ash.read!(authorize?: false)
    |> Enum.group_by(& &1.model_name)
    |> Enum.map(fn {model, usages} ->
      %{
        model: model || "Unknown",
        count: length(usages),
        cost:
          Enum.reduce(usages, Decimal.new(0), fn u, acc ->
            Decimal.add(acc, u.total_cost || Decimal.new(0))
          end)
      }
    end)
    |> Enum.sort_by(& &1.count, :desc)
    |> Enum.take(10)
  end

  defp get_cost_by_model do
    require Ash.Query

    Magus.Usage.MessageUsage
    |> Ash.read!(authorize?: false)
    |> Enum.group_by(& &1.model_name)
    |> Enum.map(fn {model, usages} ->
      %{
        model: model || "Unknown",
        cost:
          Enum.reduce(usages, Decimal.new(0), fn u, acc ->
            Decimal.add(acc, u.total_cost || Decimal.new(0))
          end),
        count: length(usages)
      }
    end)
    |> Enum.sort_by(& &1.cost, {:desc, Decimal})
    |> Enum.take(10)
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_metrics(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="space-y-6">
        <%!-- Header --%>
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-base-content">Dashboard</h1>
            <p class="text-base-content/60 text-sm mt-1">
              Overview of your platform's activity and usage
            </p>
          </div>
          <button type="button" phx-click="refresh" class="btn btn-outline btn-sm">
            <.icon name="lucide-refresh-cw" class="w-4 h-4" /> Refresh
          </button>
        </div>

        <%!-- Metrics Cards --%>
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
          <.metric_card
            title="Active Users"
            value={@active_users}
            subtitle="Last 15 minutes"
            icon="lucide-users"
            color="primary"
          />
          <.metric_card
            title="Total Users"
            value={@total_users}
            subtitle="Registered users"
            icon="lucide-users"
            color="secondary"
          />
          <.metric_card
            title="Total Messages"
            value={format_number(@total_messages)}
            subtitle="All time"
            icon="lucide-messages-square"
            color="accent"
          />
          <.metric_card
            title="Total Cost"
            value={format_cost(@total_cost)}
            subtitle="All usage"
            icon="lucide-dollar-sign"
            color="warning"
          />
        </div>

        <%!-- Activity Chart --%>
        <.live_component
          module={MagusWeb.Admin.Components.ActivityChartComponent}
          id="platform-activity"
          title="Platform Message Activity"
        />

        <%!-- Charts Section --%>
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <%!-- Most Popular Models --%>
          <div class="card bg-base-200 border border-base-300">
            <div class="card-body">
              <h2 class="card-title text-base-content">Most Popular Models</h2>
              <p class="text-sm text-base-content/60">Top models by usage count</p>
              <div class="mt-4 space-y-2">
                <%= if @popular_models == [] do %>
                  <p class="text-center text-base-content/50 py-8">No usage data available</p>
                <% else %>
                  <div class="space-y-3">
                    <%= for model <- @popular_models do %>
                      <div class="flex items-center justify-between p-2 bg-base-300/50 rounded-lg">
                        <div>
                          <p class="font-medium text-base-content text-sm">{model.model}</p>
                          <p class="text-xs text-base-content/60">{format_cost(model.cost)}</p>
                        </div>
                        <span class="font-mono text-lg font-bold text-base-content">
                          {format_number(model.count)}
                        </span>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          </div>

          <%!-- Cost by Model --%>
          <div class="card bg-base-200 border border-base-300">
            <div class="card-body">
              <h2 class="card-title text-base-content">Cost by Model</h2>
              <p class="text-sm text-base-content/60">Top models by usage cost</p>
              <div class="mt-4 space-y-2">
                <%= if @cost_by_model == [] do %>
                  <p class="text-center text-base-content/50 py-8">No cost data available</p>
                <% else %>
                  <div class="space-y-3">
                    <%= for model <- @cost_by_model do %>
                      <div class="flex items-center justify-between p-2 bg-base-300/50 rounded-lg">
                        <div>
                          <p class="font-medium text-base-content text-sm">{model.model}</p>
                          <p class="text-xs text-base-content/60">{model.count} requests</p>
                        </div>
                        <span class="font-mono text-sm text-base-content">
                          {format_cost(model.cost)}
                        </span>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.admin>
    """
  end

  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :subtitle, :string, required: true
  attr :icon, :string, required: true
  attr :color, :string, default: "primary"

  defp metric_card(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300">
      <div class="card-body p-4">
        <div class="flex items-start justify-between">
          <div>
            <p class="text-sm font-medium text-base-content/60">{@title}</p>
            <p class="text-2xl font-bold text-base-content mt-1">{@value}</p>
            <p class="text-xs text-base-content/50 mt-1">{@subtitle}</p>
          </div>
          <div class={"p-2 rounded-lg bg-#{@color}/10"}>
            <.icon name={@icon} class={"w-6 h-6 text-#{@color}"} />
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_number(num) when is_integer(num) do
    num
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_number(num), do: to_string(num)

  defp format_cost(decimal) do
    "$" <> (decimal |> Decimal.round(4) |> Decimal.to_string())
  end
end
