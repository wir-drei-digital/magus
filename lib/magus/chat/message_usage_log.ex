defmodule Magus.Chat.MessageUsageLog do
  @moduledoc """
  Query + aggregation logic for the per-user Settings "Usage" page.

  All `MessageUsage` reads pass `actor: user` so the read policy scopes to the
  caller. The subscription lookup in `default_period/1` uses `authorize?: false`
  (it only reads the caller's own period boundaries). Costs are stored per row in
  USD (`total_cost`); this module converts to internal cost units via
  the `Magus.Usage.ExchangeRate` seam for display.
  """
  require Ash.Query

  @period_lookback_days 30
  @per_page 25

  @doc """
  Full payload for the SPA settings "Usage" page, built for the
  `Magus.Usage.MessageUsage.usage_log` generic action. `params` carries the
  RPC arguments (`:range`, `:model_name`, `:workspace`, `:page`); everything
  is serialized to JSON-safe values (ISO datetimes, stringified decimals).
  """
  def rpc_payload(user, params) do
    {from, to, label} = resolve_range(params[:range], user)

    filters = %{
      from: from,
      to: to,
      model_name: blank_to_nil(params[:model_name]),
      workspace: parse_workspace(params[:workspace])
    }

    page_num = max(params[:page] || 1, 1)

    %{rows: rows, total_count: total_count, total_pages: total_pages} =
      page(user, filters, page: page_num, per_page: @per_page)

    summary = summary(user, filters)

    %{
      period_label: to_string(label),
      page: page_num,
      per_page: @per_page,
      total_count: total_count,
      total_pages: total_pages,
      summary: %{
        count: summary.count,
        total_tokens: summary.total_tokens,
        total_cost_chf: chf_string(summary.total_cost_chf)
      },
      model_options: used_model_names(user),
      rows: Enum.map(rows, &serialize_row/1)
    }
  end

  defp serialize_row(row) do
    %{
      id: row.id,
      inserted_at: DateTime.to_iso8601(row.inserted_at),
      model_name: row.model_name,
      usage_type: to_string(row.usage_type),
      prompt_tokens: row.prompt_tokens,
      completion_tokens: row.completion_tokens,
      total_tokens: row.total_tokens,
      cost_chf: row.total_cost |> usd_to_chf() |> chf_string(),
      reconciliation_status: to_string(row.reconciliation_status),
      conversation_id: row.conversation_id,
      message_id: row.message_id
    }
  end

  defp chf_string(%Decimal{} = chf),
    do: chf |> Decimal.round(4) |> Decimal.to_string(:normal)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp parse_workspace("personal"), do: :personal

  defp parse_workspace(ws_id) when is_binary(ws_id) and ws_id not in ["", "all"],
    do: {:workspace, ws_id}

  defp parse_workspace(_), do: :all

  defp resolve_range("7d", _user), do: last_days(7)
  defp resolve_range("30d", _user), do: last_days(30)
  defp resolve_range("90d", _user), do: last_days(90)
  defp resolve_range("all", _user), do: {~U[2000-01-01 00:00:00Z], DateTime.utc_now(), :all_time}

  defp resolve_range("month", _user) do
    now = DateTime.utc_now()
    start = %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}
    {start, now, :this_month}
  end

  # "current_period" and anything unrecognized fall back to the default window.
  defp resolve_range(_other, user), do: default_period(user)

  defp last_days(n),
    do: {DateTime.add(DateTime.utc_now(), -n, :day), DateTime.utc_now(), :"last_#{n}_days"}

  @doc """
  The default time window for a user: their Stripe billing cycle when present,
  else the last 30 days. Returns `{from_dt, to_dt, label}` where label is
  `:billing_period | :last_30_days`.
  """
  def default_period(user) do
    case Magus.Usage.get_user_subscription(user.id, authorize?: false) do
      {:ok, %{current_period_start: %DateTime{} = start}} ->
        {start, DateTime.utc_now(), :billing_period}

      _ ->
        now = DateTime.utc_now()
        {DateTime.add(now, -@period_lookback_days, :day), now, :last_30_days}
    end
  end

  @doc """
  Builds the filtered, user-scoped `MessageUsage` query. `filters` is a map:

      %{from: DateTime.t(), to: DateTime.t(),
        model_name: String.t() | nil,
        workspace: :all | :personal | {:workspace, ws_id}}
  """
  # Returns an UN-scoped query; user scoping is applied at execution via
  # `actor: user` (the read policy). Always execute with `actor:`, never
  # `authorize?: false`.
  def base_query(_user, filters) do
    Magus.Usage.MessageUsage
    |> Ash.Query.filter(billable == true)
    |> Ash.Query.filter(inserted_at >= ^filters.from and inserted_at <= ^filters.to)
    |> apply_model_filter(filters.model_name)
    |> apply_workspace_filter(filters.workspace)
  end

  defp apply_model_filter(query, nil), do: query

  defp apply_model_filter(query, name),
    do: Ash.Query.filter(query, model_name == ^name)

  defp apply_workspace_filter(query, :all), do: query

  defp apply_workspace_filter(query, :personal),
    do: Ash.Query.filter(query, is_nil(conversation.workspace_id))

  defp apply_workspace_filter(query, {:workspace, ws_id}),
    do: Ash.Query.filter(query, conversation.workspace_id == ^ws_id)

  @doc "Total billable record count for the filtered window."
  def count(user, filters) do
    base_query(user, filters) |> Ash.count!(actor: user)
  end

  @doc """
  Aggregates the filtered window: record count, summed tokens, and summed cost
  converted to CHF. Returns `%{count, total_tokens, total_cost_chf}`.
  """
  def summary(user, filters) do
    query = base_query(user, filters)

    usd = Ash.sum!(query, :total_cost, actor: user) || Decimal.new(0)

    %{
      count: Ash.count!(query, actor: user),
      total_tokens: Ash.sum!(query, :total_tokens, actor: user) || 0,
      total_cost_chf: usd_to_chf(usd)
    }
  end

  @doc "Converts a USD `Decimal` to CHF using the current FX rate."
  def usd_to_chf(%Decimal{} = usd),
    do: Decimal.mult(usd, Magus.Usage.ExchangeRate.usd_to_chf())

  def usd_to_chf(_), do: Decimal.new(0)

  @doc """
  Returns one offset page of filtered rows, newest first, plus pagination
  metadata. `opts`: `:page` (1-based), `:per_page`. Returns
  `%{rows, total_count, total_pages, page, per_page}`.
  """
  def page(user, filters, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = Keyword.get(opts, :per_page, 25)
    query = base_query(user, filters)

    total_count = Ash.count!(query, actor: user)

    rows =
      query
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.offset((page - 1) * per_page)
      |> Ash.Query.limit(per_page)
      |> Ash.read!(actor: user)

    %{
      rows: rows,
      total_count: total_count,
      total_pages: max(ceil(total_count / per_page), 1),
      page: page,
      per_page: per_page
    }
  end

  @doc "Distinct model names that appear in this user's billable usage, sorted."
  def used_model_names(user) do
    Magus.Usage.MessageUsage
    |> Ash.Query.filter(billable == true)
    |> Ash.Query.distinct([:model_name])
    |> Ash.Query.select([:model_name])
    |> Ash.Query.sort(model_name: :asc)
    |> Ash.read!(actor: user)
    |> Enum.map(& &1.model_name)
  end
end
