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
