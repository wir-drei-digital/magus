defmodule MagusWeb.Workbench.Detail.UsageSection do
  @moduledoc """
  The "Usage" settings section, rendered inside `MagusWeb.Workbench.Detail.SettingsView`.

  Provides a reactive summary (tokens, CHF cost, count) over the current billing
  period by default, and a paged, filterable table of billable `MessageUsage`
  rows. All data goes through `Magus.Chat.MessageUsageLog` with
  `actor: current_user`, so the read policy scopes to the user.

  This module is never routed directly — `SettingsView` calls `init_assigns/2`,
  `render_section/1`, and `handle_event/3` as a function provider. It is
  `use MagusWeb, :live_view` only to get `~H`, components, `~p`, `gettext`,
  `assign`, and `stream`.
  """
  use MagusWeb, :live_view

  alias Magus.Chat.MessageUsageLog
  alias Magus.Workspaces

  @per_page 25

  @doc """
  Builds the section's assigns, minus the shell bits (`:page_title`,
  `:current_path`). Reads the current user from the passed
  `user` for option-loading; `load_summary/1` and `load_rows/1` read
  `socket.assigns.current_user` (assigned by `SettingsView` before this runs).
  Returns the socket.
  """
  def init_assigns(socket, user) do
    {from, to, label} = MessageUsageLog.default_period(user)

    filters = %{from: from, to: to, model_name: nil, workspace: :all}

    socket
    |> assign(:period_label, label)
    |> assign(:range_key, "current_period")
    |> assign(:filters, filters)
    |> assign(:page, 1)
    |> assign(:per_page, @per_page)
    |> assign(:model_options, MessageUsageLog.used_model_names(user))
    |> assign(:workspace_options, list_workspaces(user))
    |> load_summary()
    |> load_rows()
  end

  def handle_event("apply_filters", %{"filters" => params}, socket) do
    user = socket.assigns.current_user
    {from, to, label} = resolve_range(params["range"], user)

    filters = %{
      from: from,
      to: to,
      model_name: blank_to_nil(params["model_name"]),
      workspace: parse_workspace(params["workspace"])
    }

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:range_key, params["range"])
     |> assign(:period_label, label)
     |> assign(:page, 1)
     |> load_summary()
     |> load_rows()}
  end

  def handle_event("page", %{"to" => to}, socket) do
    page = to |> String.to_integer() |> max(1) |> min(socket.assigns.total_pages)
    {:noreply, socket |> assign(:page, page) |> load_rows()}
  end

  defp list_workspaces(user) do
    case Workspaces.my_workspaces(actor: user) do
      {:ok, workspaces} -> workspaces
      _ -> []
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp parse_workspace("all"), do: :all
  defp parse_workspace("personal"), do: :personal
  defp parse_workspace(ws_id) when is_binary(ws_id) and ws_id != "", do: {:workspace, ws_id}
  defp parse_workspace(_), do: :all

  defp resolve_range("current_period", user), do: MessageUsageLog.default_period(user)
  defp resolve_range("7d", _user), do: last_days(7)
  defp resolve_range("30d", _user), do: last_days(30)
  defp resolve_range("90d", _user), do: last_days(90)
  defp resolve_range("all", _user), do: {~U[2000-01-01 00:00:00Z], DateTime.utc_now(), :all_time}

  defp resolve_range("month", _user) do
    now = DateTime.utc_now()
    start = %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}
    {start, now, :this_month}
  end

  defp resolve_range(_other, user), do: MessageUsageLog.default_period(user)

  defp last_days(n),
    do: {DateTime.add(DateTime.utc_now(), -n, :day), DateTime.utc_now(), :"last_#{n}_days"}

  defp load_summary(socket) do
    summary = MessageUsageLog.summary(socket.assigns.current_user, socket.assigns.filters)
    assign(socket, :summary, summary)
  end

  defp load_rows(socket) do
    %{rows: rows, total_count: total, total_pages: pages} =
      MessageUsageLog.page(socket.assigns.current_user, socket.assigns.filters,
        page: socket.assigns.page,
        per_page: socket.assigns.per_page
      )

    socket
    |> assign(:total_count, total)
    |> assign(:total_pages, pages)
    |> assign(:rows_empty?, rows == [])
    |> stream(:rows, rows, reset: true)
  end

  def render_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <h2 class="text-xl font-semibold">{gettext("Usage")}</h2>
      <p class="text-base-content/70 text-sm">
        {gettext(
          "Amounts shown are usage cost. See Subscription for the amount invoiced after any credit and cap."
        )}
      </p>
      <form id="usage-filters" phx-change="apply_filters" class="flex flex-wrap gap-3 items-end">
        <label class="form-control">
          <span class="label-text text-xs">{gettext("Time range")}</span>
          <select name="filters[range]" class="select select-bordered select-sm">
            <option value="current_period" selected={@range_key == "current_period"}>
              {gettext("Current period")}
            </option>
            <option value="7d" selected={@range_key == "7d"}>{gettext("Last 7 days")}</option>
            <option value="30d" selected={@range_key == "30d"}>
              {gettext("Last 30 days")}
            </option>
            <option value="90d" selected={@range_key == "90d"}>
              {gettext("Last 90 days")}
            </option>
            <option value="month" selected={@range_key == "month"}>
              {gettext("This month")}
            </option>
            <option value="all" selected={@range_key == "all"}>{gettext("All time")}</option>
          </select>
        </label>

        <label class="form-control">
          <span class="label-text text-xs">{gettext("Model")}</span>
          <select name="filters[model_name]" class="select select-bordered select-sm">
            <option value="">{gettext("All models")}</option>
            <option
              :for={name <- @model_options}
              value={name}
              selected={@filters.model_name == name}
            >
              {name}
            </option>
          </select>
        </label>

        <label class="form-control">
          <span class="label-text text-xs">{gettext("Workspace")}</span>
          <select name="filters[workspace]" class="select select-bordered select-sm">
            <option value="all" selected={@filters.workspace == :all}>{gettext("All")}</option>
            <option value="personal" selected={@filters.workspace == :personal}>
              {gettext("Personal")}
            </option>
            <option
              :for={ws <- @workspace_options}
              value={ws.id}
              selected={@filters.workspace == {:workspace, ws.id}}
            >
              {ws.name}
            </option>
          </select>
        </label>
      </form>

      <div data-testid="period-caption" class="text-sm text-base-content/60">
        {gettext("Showing:")} {period_caption(@period_label)}
      </div>

      <div class="grid grid-cols-2 md:grid-cols-3 gap-4">
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body p-4">
            <div class="text-xs text-base-content/60">{gettext("Total tokens")}</div>
            <div data-testid="summary-token-total" class="text-xl font-semibold">
              {humanize_tokens(@summary.total_tokens)}
            </div>
          </div>
        </div>
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body p-4">
            <div class="text-xs text-base-content/60">{gettext("Total cost")}</div>
            <div data-testid="summary-cost-total" class="text-xl font-semibold">
              {format_chf(@summary.total_cost_chf)}
            </div>
          </div>
        </div>
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body p-4">
            <div class="text-xs text-base-content/60">{gettext("Records")}</div>
            <div data-testid="summary-count" class="text-xl font-semibold">
              {@summary.count}
            </div>
          </div>
        </div>
      </div>

      <div
        :if={@rows_empty?}
        data-testid="usage-empty"
        class="p-6 text-center text-base-content/60 rounded border border-base-300"
      >
        {gettext("No billable usage in this period.")}
      </div>

      <div :if={not @rows_empty?} class="overflow-x-auto rounded border border-base-300">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>{gettext("Date")}</th>
              <th>{gettext("Model")}</th>
              <th>{gettext("Type")}</th>
              <th class="text-right">{gettext("Prompt")}</th>
              <th class="text-right">{gettext("Completion")}</th>
              <th class="text-right">{gettext("Tokens")}</th>
              <th class="text-right">{gettext("Cost")}</th>
              <th></th>
            </tr>
          </thead>
          <tbody id="usage-rows" phx-update="stream">
            <tr :for={{id, row} <- @streams.rows} id={id} data-testid="usage-row">
              <td class="whitespace-nowrap">{format_date(row.inserted_at)}</td>
              <td>{row.model_name}</td>
              <td>
                <span class="badge badge-ghost badge-sm">{row.usage_type}</span>
                <span
                  :if={row.reconciliation_status == :pending}
                  class="badge badge-warning badge-sm"
                  title={gettext("Provisional, awaiting reconciliation")}
                >
                  ~
                </span>
              </td>
              <td class="text-right">{row.prompt_tokens}</td>
              <td class="text-right">{row.completion_tokens}</td>
              <td class="text-right">{row.total_tokens}</td>
              <td class="text-right">
                {format_chf(MessageUsageLog.usd_to_chf(row.total_cost))}
              </td>
              <td class="text-right">
                <.link
                  :if={row.conversation_id && row.message_id}
                  navigate={~p"/chat/#{row.conversation_id}?highlight=#{row.message_id}"}
                  class="link link-primary"
                >
                  {gettext("View")}
                </.link>
                <span
                  :if={is_nil(row.conversation_id) || is_nil(row.message_id)}
                  class="text-base-content/40"
                >
                  —
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={not @rows_empty?} class="flex items-center justify-between mt-3">
        <span class="text-sm text-base-content/60">
          {gettext("%{count} records", count: @total_count)}
        </span>
        <div class="join">
          <button
            class="btn btn-sm join-item"
            data-testid="page-prev"
            phx-click="page"
            phx-value-to={@page - 1}
            disabled={@page <= 1}
          >
            «
          </button>
          <span class="btn btn-sm join-item no-animation" data-testid="page-indicator">
            {@page} / {@total_pages}
          </span>
          <button
            class="btn btn-sm join-item"
            data-testid="page-next"
            phx-click="page"
            phx-value-to={@page + 1}
            disabled={@page >= @total_pages}
          >
            »
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp format_chf(%Decimal{} = chf),
    do: "CHF " <> (chf |> Decimal.round(4) |> Decimal.to_string(:normal))

  defp format_chf(_), do: format_chf(Decimal.new(0))

  defp period_caption(:billing_period), do: gettext("Current billing period")
  defp period_caption(:this_month), do: gettext("This month")
  defp period_caption(:all_time), do: gettext("All time")
  defp period_caption(:last_7_days), do: gettext("Last 7 days")
  defp period_caption(:last_30_days), do: gettext("Last 30 days")
  defp period_caption(:last_90_days), do: gettext("Last 90 days")
  defp period_caption(_), do: gettext("Selected period")

  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_date(_), do: "—"

  # Human-friendly token counts: 25_500_000 -> "25.5M", 1_000 -> "1K",
  # 999 -> "999". One decimal place, trailing ".0" trimmed.
  defp humanize_tokens(n) when is_integer(n) and n >= 1_000_000_000,
    do: abbrev_tokens(n, 1_000_000_000, "B")

  defp humanize_tokens(n) when is_integer(n) and n >= 1_000_000,
    do: abbrev_tokens(n, 1_000_000, "M")

  defp humanize_tokens(n) when is_integer(n) and n >= 1_000,
    do: abbrev_tokens(n, 1_000, "K")

  defp humanize_tokens(n) when is_integer(n), do: Integer.to_string(n)
  defp humanize_tokens(_), do: "0"

  # Integer math (round to nearest tenth) avoids float rounding artifacts.
  defp abbrev_tokens(n, divisor, suffix) do
    tenths = div(n * 10 + div(divisor, 2), divisor)
    whole = div(tenths, 10)
    frac = rem(tenths, 10)

    if frac == 0 do
      "#{whole}#{suffix}"
    else
      "#{whole}.#{frac}#{suffix}"
    end
  end
end
