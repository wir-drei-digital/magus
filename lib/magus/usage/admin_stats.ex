defmodule Magus.Usage.AdminStats do
  @moduledoc """
  Read-only SQL rollups backing the admin dashboard, users and usage views.

  Admin analytics need whole-table GROUP BYs (per model, per user, per time
  bucket) that Ash's aggregate API doesn't express, so this module queries the
  resources directly with Ecto — the same escape hatch as
  `Magus.Models.ModelReferences` and `Magus.Workspaces.MemberUsage`. Nothing
  here writes; callers are the admin-only LiveViews (`authorize?: false`
  territory), so no actor scoping is applied.
  """

  import Ecto.Query

  alias Magus.Accounts.User
  alias Magus.Chat.Message
  alias Magus.Repo
  alias Magus.Usage.Account
  alias Magus.Usage.MessageUsage
  alias Magus.Usage.Policy

  @typedoc "Common filters: `:since` (DateTime) and `:model` (model_name) — nil means unfiltered."
  @type filters :: [since: DateTime.t() | nil, model: String.t() | nil]

  # ── Dashboard ───────────────────────────────────────────────────────────────

  @doc "Platform-wide counters for the dashboard metric cards."
  def overview do
    fifteen_minutes_ago = DateTime.add(DateTime.utc_now(), -15, :minute)

    %{
      total_users: Repo.one(from(u in User, select: count(u.id))),
      active_users:
        Repo.one(
          from(mu in MessageUsage,
            where: mu.inserted_at >= ^fifteen_minutes_ago,
            select: count(mu.user_id, :distinct)
          )
        ),
      total_messages: Repo.one(from(m in Message, select: count(m.id))),
      total_cost: Repo.one(from(mu in MessageUsage, select: sum(mu.total_cost))) || Decimal.new(0)
    }
  end

  # ── Usage analytics ─────────────────────────────────────────────────────────

  @doc "Request/billable/cost/token totals for the filter window."
  @spec summary(filters()) :: map()
  def summary(filters \\ []) do
    result =
      usage_base(filters)
      |> select([mu], %{
        total_requests: count(mu.id),
        billable_count: fragment("COUNT(*) FILTER (WHERE ?)", mu.billable),
        total_cost: sum(mu.total_cost),
        total_tokens: sum(mu.total_tokens)
      })
      |> Repo.one()

    %{
      result
      | total_cost: result.total_cost || Decimal.new(0),
        total_tokens: to_int(result.total_tokens)
    }
  end

  @doc "Per-model request count and cost, most expensive first."
  @spec model_totals(filters()) :: [map()]
  def model_totals(filters \\ []) do
    usage_base(filters)
    |> group_by([mu], mu.model_name)
    |> select([mu], %{model: mu.model_name, count: count(mu.id), cost: sum(mu.total_cost)})
    |> order_by([mu], desc: sum(mu.total_cost))
    |> Repo.all()
    |> Enum.map(&normalize_totals_row/1)
  end

  @doc "Per-action request count and cost, most expensive first."
  @spec action_totals(filters()) :: [map()]
  def action_totals(filters \\ []) do
    usage_base(filters)
    |> group_by([mu], mu.action_name)
    |> select([mu], %{action: mu.action_name, count: count(mu.id), cost: sum(mu.total_cost)})
    |> order_by([mu], desc: sum(mu.total_cost))
    |> Repo.all()
    |> Enum.map(&normalize_totals_row/1)
  end

  @doc """
  Request counts per time bucket and series. `series` groups each bucket a
  second time: `:billable` (boolean) or `:action` (action_name).
  `bucket_seconds` aligns buckets to epoch multiples (3600 = clock hours,
  86400 = UTC days). Only non-empty buckets are returned; callers fill gaps.
  """
  @spec bucketed_counts(:billable | :action, pos_integer(), filters()) :: [map()]
  def bucketed_counts(series, bucket_seconds, filters \\ [])
      when series in [:billable, :action] do
    # Bucket per row in a subquery, group outside: Postgres can't match a
    # SELECT expression to the GROUP BY when each carries its own bind params.
    per_row =
      case series do
        :billable ->
          select(usage_base(filters), [mu], %{
            bucket:
              fragment(
                "to_timestamp(floor(extract(epoch from ?) / ?) * ?)",
                mu.inserted_at,
                ^bucket_seconds,
                ^bucket_seconds
              ),
            series: mu.billable
          })

        :action ->
          select(usage_base(filters), [mu], %{
            bucket:
              fragment(
                "to_timestamp(floor(extract(epoch from ?) / ?) * ?)",
                mu.inserted_at,
                ^bucket_seconds,
                ^bucket_seconds
              ),
            series: mu.action_name
          })
      end

    from(r in subquery(per_row),
      group_by: [r.bucket, r.series],
      select: %{bucket: r.bucket, series: r.series, count: count()}
    )
    |> Repo.all()
  end

  @token_bin_edges [100, 1_000, 10_000, 100_000, 1_000_000]
  @token_bin_labels ["0-100", "100-1K", "1K-10K", "10K-100K", "100K-1M", "1M+"]

  @doc """
  Token-count histogram over logarithmic bins plus the median, computed in SQL
  (`width_bucket` + `percentile_cont`). Returns `%{labels: [...], counts: [...],
  median: integer}` with one count per label, zero-filled.
  """
  @spec token_histogram(filters()) :: map()
  def token_histogram(filters \\ []) do
    base = usage_base(filters) |> where([mu], not is_nil(mu.total_tokens))

    counts_by_bin =
      base
      |> group_by(
        [mu],
        fragment("width_bucket(?, ARRAY[100,1000,10000,100000,1000000])", mu.total_tokens)
      )
      |> select([mu], {
        fragment("width_bucket(?, ARRAY[100,1000,10000,100000,1000000])", mu.total_tokens),
        count(mu.id)
      })
      |> Repo.all()
      |> Map.new()

    median =
      base
      |> select([mu], fragment("percentile_cont(0.5) WITHIN GROUP (ORDER BY ?)", mu.total_tokens))
      |> Repo.one()

    %{
      labels: @token_bin_labels,
      counts: Enum.map(0..length(@token_bin_edges), &Map.get(counts_by_bin, &1, 0)),
      median: round(median || 0)
    }
  end

  @doc "Request counts per finish_reason, most frequent first."
  @spec finish_reasons(filters()) :: [map()]
  def finish_reasons(filters \\ []) do
    usage_base(filters)
    |> group_by([mu], mu.finish_reason)
    |> select([mu], %{reason: mu.finish_reason, count: count(mu.id)})
    |> order_by([mu], desc: count(mu.id))
    |> Repo.all()
  end

  @doc "Per-user usage rollup (requests, billable, cost, tokens) with email."
  @spec user_totals(filters()) :: [map()]
  def user_totals(filters \\ []) do
    usage_base(filters)
    |> join(:left, [mu], u in User, on: u.id == mu.user_id)
    |> group_by([mu, u], [mu.user_id, u.email])
    |> select([mu, u], %{
      user_id: mu.user_id,
      email: u.email,
      total_requests: count(mu.id),
      billable_requests: fragment("COUNT(*) FILTER (WHERE ?)", mu.billable),
      total_cost: sum(mu.total_cost),
      total_tokens: sum(mu.total_tokens)
    })
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        row
        | email: row.email && to_string(row.email),
          total_cost: row.total_cost || Decimal.new(0),
          total_tokens: to_int(row.total_tokens)
      }
    end)
  end

  @doc "Distinct model names present in the filter window, sorted."
  @spec model_names(filters()) :: [String.t()]
  def model_names(filters \\ []) do
    usage_base(filters)
    |> where([mu], not is_nil(mu.model_name))
    |> distinct(true)
    |> select([mu], mu.model_name)
    |> order_by([mu], asc: mu.model_name)
    |> Repo.all()
  end

  # ── Users table ─────────────────────────────────────────────────────────────

  @user_sorts ~w(email display_name inserted_at message_count total_cost last_active plan)

  @doc "Sort columns `list_users/1` accepts."
  def user_sorts, do: @user_sorts

  @doc """
  One page of the admin users table: each user joined with their usage rollup
  (message count, total cost, last activity) and personal plan name, sortable
  on any of `user_sorts/0` — aggregates sort in SQL, so ordering by cost or
  activity is correct across pages, not just within one.

  Options: `:search`, `:filter` ("admins" | "non_admins" | "demo"),
  `:sort`, `:dir` ("asc" | "desc"), `:page`, `:per_page`.

  Returns `%{users: [map], total_count: n}`.
  """
  def list_users(opts \\ []) do
    search = opts[:search] || ""
    filter = opts[:filter] || "all"
    sort = if opts[:sort] in @user_sorts, do: opts[:sort], else: "inserted_at"
    dir = if opts[:dir] == "asc", do: :asc, else: :desc
    page = max(opts[:page] || 1, 1)
    per_page = opts[:per_page] || 20

    total_count = Repo.one(select(filtered_users(search, filter), [u], count(u.id)))

    usage_rollup =
      from(mu in MessageUsage,
        group_by: mu.user_id,
        select: %{
          user_id: mu.user_id,
          message_count: count(mu.id),
          total_cost: sum(mu.total_cost),
          last_active: max(mu.inserted_at)
        }
      )

    users =
      filtered_users(search, filter)
      |> join(:left, [u], mu in subquery(usage_rollup), on: mu.user_id == u.id)
      |> join(:left, [u], s in Account, on: s.user_id == u.id)
      |> join(:left, [u, mu, s], p in Policy, on: p.id == s.usage_plan_id)
      |> select([u, mu, s, p], %{
        id: u.id,
        email: u.email,
        display_name: u.display_name,
        is_admin: u.is_admin,
        test_account: u.test_account,
        inserted_at: u.inserted_at,
        message_count: coalesce(mu.message_count, 0),
        total_cost: coalesce(mu.total_cost, 0),
        last_active: mu.last_active,
        plan_name: p.name
      })
      |> order_users(sort, dir)
      |> offset(^((page - 1) * per_page))
      |> limit(^per_page)
      |> Repo.all()
      |> Enum.map(fn user -> %{user | email: to_string(user.email)} end)

    %{users: users, total_count: total_count}
  end

  defp filtered_users(search, filter) do
    query = from(u in User)

    query =
      if search != "" do
        pattern = "%" <> escape_like(search) <> "%"
        where(query, [u], ilike(u.email, ^pattern) or ilike(u.display_name, ^pattern))
      else
        query
      end

    case filter do
      "admins" -> where(query, [u], u.is_admin == true)
      "non_admins" -> where(query, [u], u.is_admin == false)
      "demo" -> where(query, [u], u.test_account == true)
      _ -> query
    end
  end

  # Secondary key keeps ordering stable across pages when the primary ties.
  defp order_users(query, sort, dir) do
    query = order_by(query, [u, mu], ^order_expr(sort, dir))
    order_by(query, [u], asc: u.id)
  end

  defp order_expr("email", dir), do: [{dir, dynamic([u], u.email)}]
  defp order_expr("display_name", dir), do: [{nulls_last(dir), dynamic([u], u.display_name)}]
  defp order_expr("inserted_at", dir), do: [{dir, dynamic([u], u.inserted_at)}]

  defp order_expr("message_count", dir),
    do: [{dir, dynamic([u, mu], coalesce(mu.message_count, 0))}]

  defp order_expr("total_cost", dir), do: [{dir, dynamic([u, mu], coalesce(mu.total_cost, 0))}]
  defp order_expr("last_active", dir), do: [{nulls_last(dir), dynamic([u, mu], mu.last_active)}]
  defp order_expr("plan", dir), do: [{nulls_last(dir), dynamic([u, mu, s, p], p.name)}]

  # Users without the value (never active, no plan, no name) sort last in both
  # directions instead of Postgres's NULLS FIRST default on DESC.
  defp nulls_last(:asc), do: :asc_nulls_last
  defp nulls_last(:desc), do: :desc_nulls_last

  defp escape_like(term), do: String.replace(term, ~r/([\\%_])/, "\\\\\\1")

  # ── Plans ───────────────────────────────────────────────────────────────────

  @doc "Active/trialing subscriber count per usage plan id."
  @spec plan_subscriber_counts() :: %{optional(Ecto.UUID.t()) => non_neg_integer()}
  def plan_subscriber_counts do
    from(s in Account,
      where: s.status in [:active, :trialing],
      group_by: s.usage_plan_id,
      select: {s.usage_plan_id, count(s.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Query base with the common :since / :model / :user_id filters applied.
  defp usage_base(filters) do
    query = from(mu in MessageUsage)

    query =
      case filters[:since] do
        nil -> query
        since -> where(query, [mu], mu.inserted_at >= ^since)
      end

    query =
      case filters[:model] do
        nil -> query
        model -> where(query, [mu], mu.model_name == ^model)
      end

    case filters[:user_id] do
      nil -> query
      user_id -> where(query, [mu], mu.user_id == ^user_id)
    end
  end

  defp normalize_totals_row(row), do: %{row | cost: row.cost || Decimal.new(0)}

  # SUM over a bigint column returns numeric (Decimal); counts stay integers.
  defp to_int(nil), do: 0
  defp to_int(%Decimal{} = d), do: Decimal.to_integer(Decimal.round(d))
  defp to_int(n) when is_integer(n), do: n
end
