defmodule Magus.Usage.AdminStatsTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Usage.AdminStats

  # The shared test DB can contain committed leftovers from live/build test
  # runs, so every assertion scopes to rows seeded by this test: usage rows
  # via a unique model name, users via a unique email prefix.
  defp unique_tag, do: "astats#{System.unique_integer([:positive])}"

  defp tagged_user(tag, suffix) do
    generate(user(email: "#{tag}-#{suffix}@test.com"))
  end

  defp seed_usage(user, tag, attrs) do
    defaults = %{
      user_id: user.id,
      usage_type: :response,
      model_name: tag,
      action_name: "chat",
      billable: true,
      prompt_tokens: 100,
      completion_tokens: 100,
      total_tokens: 200,
      total_cost: Decimal.new("0.5")
    }

    Ash.Seed.seed!(Magus.Usage.MessageUsage, Map.merge(defaults, Map.new(attrs)))
  end

  defp make_demo(user) do
    user
    |> Ash.Changeset.for_update(:update_profile, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:test_account, true)
    |> Ash.update!(authorize?: false)
  end

  # Registration may already have created a personal (free-plan) subscription;
  # users must end up with exactly one personal Account row either way.
  defp put_personal_plan(user, plan, status) do
    {count, _} =
      Magus.Repo.update_all(
        from(a in Magus.Usage.Account,
          where: a.user_id == ^user.id
        ),
        set: [usage_plan_id: plan.id, status: status]
      )

    if count == 0 do
      Ash.Seed.seed!(Magus.Usage.Account, %{
        user_id: user.id,
        usage_plan_id: plan.id,
        status: status
      })
    end
  end

  describe "summary/1" do
    test "aggregates counts, billable, cost and tokens in the window" do
      tag = unique_tag()
      user = generate(user())
      seed_usage(user, tag, total_cost: Decimal.new("1.0"), billable: true)
      seed_usage(user, tag, total_cost: Decimal.new("0.25"), billable: false)

      summary = AdminStats.summary(model: tag)

      assert summary.total_requests == 2
      assert summary.billable_count == 1
      assert Decimal.equal?(summary.total_cost, Decimal.new("1.25"))
      assert summary.total_tokens == 400
    end

    test "is all zeroes when nothing matches" do
      summary = AdminStats.summary(model: unique_tag())

      assert summary.total_requests == 0
      assert summary.billable_count == 0
      assert Decimal.equal?(summary.total_cost, Decimal.new(0))
      assert summary.total_tokens == 0
    end
  end

  describe "model_totals/1" do
    test "groups by model, most expensive first" do
      tag = unique_tag()
      user = generate(user())
      seed_usage(user, "#{tag}-cheap", total_cost: Decimal.new("0.1"))
      seed_usage(user, "#{tag}-pricey", total_cost: Decimal.new("2.0"))
      seed_usage(user, "#{tag}-pricey", total_cost: Decimal.new("2.0"))

      totals =
        AdminStats.model_totals([])
        |> Enum.filter(&String.starts_with?(&1.model || "", tag))

      assert [%{count: 2} = pricey, %{count: 1} = cheap] = totals
      assert pricey.model == "#{tag}-pricey"
      assert Decimal.equal?(pricey.cost, Decimal.new("4.0"))
      assert cheap.model == "#{tag}-cheap"
    end
  end

  describe "bucketed_counts/3" do
    test "buckets rows into epoch-aligned slots per series" do
      tag = unique_tag()
      user = generate(user())
      # Two rows in the same hour bucket, one in another.
      seed_usage(user, tag, action_name: "chat", inserted_at: ~U[2026-07-01 10:05:00.000000Z])
      seed_usage(user, tag, action_name: "chat", inserted_at: ~U[2026-07-01 10:55:00.000000Z])
      seed_usage(user, tag, action_name: "search", inserted_at: ~U[2026-07-01 11:05:00.000000Z])

      rows =
        AdminStats.bucketed_counts(:action, 3_600,
          since: ~U[2026-07-01 00:00:00.000000Z],
          model: tag
        )

      assert %{bucket: ~U[2026-07-01 10:00:00.000000Z], count: 2} =
               Enum.find(rows, &(&1.series == "chat"))

      assert %{bucket: ~U[2026-07-01 11:00:00.000000Z], count: 1} =
               Enum.find(rows, &(&1.series == "search"))
    end

    test "supports the billable series and the user filter" do
      tag = unique_tag()
      user = generate(user())
      other = generate(user())
      seed_usage(user, tag, billable: true)
      seed_usage(user, tag, billable: false)
      seed_usage(other, tag, billable: true)

      rows = AdminStats.bucketed_counts(:billable, 86_400, user_id: user.id, model: tag)

      assert rows |> Enum.map(& &1.series) |> Enum.sort() == [false, true]
      assert Enum.all?(rows, &(&1.count == 1))
    end
  end

  describe "token_histogram/1" do
    test "bins token counts logarithmically and reports the median" do
      tag = unique_tag()
      user = generate(user())
      seed_usage(user, tag, total_tokens: 50)
      seed_usage(user, tag, total_tokens: 500)
      seed_usage(user, tag, total_tokens: 5_000)

      histogram = AdminStats.token_histogram(model: tag)

      assert histogram.counts == [1, 1, 1, 0, 0, 0]
      assert histogram.median == 500
      assert length(histogram.labels) == length(histogram.counts)
    end
  end

  describe "user_totals/1" do
    test "rolls up per user with email" do
      tag = unique_tag()
      user = generate(user())
      seed_usage(user, tag, total_cost: Decimal.new("1.0"), billable: true)
      seed_usage(user, tag, total_cost: Decimal.new("0.5"), billable: false)

      assert [row] = AdminStats.user_totals(model: tag)
      assert row.user_id == user.id
      assert row.email == to_string(user.email)
      assert row.total_requests == 2
      assert row.billable_requests == 1
      assert Decimal.equal?(row.total_cost, Decimal.new("1.5"))
    end
  end

  describe "model_names/1" do
    test "returns distinct sorted names" do
      tag = unique_tag()
      user = generate(user())
      seed_usage(user, "#{tag}-b", [])
      seed_usage(user, "#{tag}-a", [])
      seed_usage(user, "#{tag}-a", [])

      names = Enum.filter(AdminStats.model_names(), &String.starts_with?(&1, tag))

      assert names == ["#{tag}-a", "#{tag}-b"]
    end
  end

  describe "list_users/1" do
    test "joins usage rollups and sorts by them across the whole set" do
      tag = unique_tag()
      light = tagged_user(tag, "light")
      heavy = tagged_user(tag, "heavy")
      seed_usage(heavy, tag, total_cost: Decimal.new("5.0"))
      seed_usage(heavy, tag, total_cost: Decimal.new("5.0"))
      seed_usage(light, tag, total_cost: Decimal.new("0.1"))

      %{users: users, total_count: 2} =
        AdminStats.list_users(search: tag, sort: "total_cost", dir: "desc")

      assert [first, second] = users
      assert first.id == heavy.id
      assert first.message_count == 2
      assert Decimal.equal?(first.total_cost, Decimal.new("10.0"))
      assert second.id == light.id
      assert %DateTime{} = first.last_active
    end

    test "users without usage get zero rollups and sort last on last_active" do
      tag = unique_tag()
      active = tagged_user(tag, "active")
      _idle = tagged_user(tag, "idle")
      seed_usage(active, tag, [])

      %{users: [first, second]} =
        AdminStats.list_users(search: tag, sort: "last_active", dir: "desc")

      assert first.id == active.id
      assert second.message_count == 0
      assert second.last_active == nil
      assert Decimal.equal?(second.total_cost, Decimal.new(0))
    end

    test "searches email with escaped like patterns" do
      user = generate(user())

      %{users: users, total_count: 1} =
        AdminStats.list_users(search: to_string(user.email))

      assert [%{id: id}] = users
      assert id == user.id

      # LIKE metacharacters must not act as wildcards.
      assert %{total_count: 0} = AdminStats.list_users(search: "#{unique_tag()}%_")
    end

    test "filters demo accounts and paginates" do
      tag = unique_tag()
      demo = make_demo(tagged_user(tag, "demo"))
      _regular = tagged_user(tag, "regular")

      assert %{users: [%{id: id}], total_count: 1} =
               AdminStats.list_users(search: tag, filter: "demo")

      assert id == demo.id

      assert %{users: [], total_count: 1} =
               AdminStats.list_users(search: tag, filter: "demo", page: 2, per_page: 20)
    end

    test "includes the personal plan name" do
      user = generate(user())
      plan = generate(usage_plan())
      put_personal_plan(user, plan, :active)

      assert %{users: [row]} = AdminStats.list_users(search: to_string(user.email))
      assert row.plan_name == plan.name
    end
  end

  describe "plan_subscriber_counts/0" do
    test "counts only active and trialing subscriptions" do
      plan = generate(usage_plan())

      for status <- [:active, :trialing, :canceled] do
        put_personal_plan(generate(user()), plan, status)
      end

      assert Map.get(AdminStats.plan_subscriber_counts(), plan.id) == 2
    end
  end

  describe "overview/0" do
    test "returns platform counters" do
      user = generate(user())
      seed_usage(user, unique_tag(), total_cost: Decimal.new("0.5"))

      overview = AdminStats.overview()

      assert overview.total_users >= 1
      assert overview.active_users >= 1
      assert overview.total_messages >= 0
      assert Decimal.compare(overview.total_cost, Decimal.new("0.5")) in [:eq, :gt]
    end
  end
end
