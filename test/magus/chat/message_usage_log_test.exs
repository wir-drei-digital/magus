defmodule Magus.Chat.MessageUsageLogTest do
  use Magus.DataCase, async: true

  import Magus.Generators
  alias Magus.Chat.MessageUsageLog

  describe "default_period/1" do
    test "falls back to last 30 days when the user has no billing cycle" do
      user = generate(user())

      {from, to, label} = MessageUsageLog.default_period(user)

      assert label == :last_30_days
      assert DateTime.diff(to, from, :day) in 29..31
    end
  end

  describe "default_period/1 with a billing cycle" do
    test "uses the subscription current_period_start" do
      user = generate(user())
      plan = generate(usage_plan())

      start = ~U[2026-06-01 00:00:00.000000Z]

      Ash.Seed.seed!(Magus.Usage.Account, %{
        user_id: user.id,
        usage_plan_id: plan.id,
        status: :active,
        current_period_start: start,
        current_period_end: ~U[2026-06-30 23:59:59.000000Z]
      })

      {from, _to, label} = MessageUsageLog.default_period(user)
      assert label == :billing_period
      assert DateTime.compare(from, start) == :eq
    end
  end

  describe "base_query/2" do
    test "scopes to billable rows, the time window, model, and workspace" do
      user = generate(user())
      model_a = generate(model(name: "Model A"))
      model_b = generate(model(name: "Model B"))
      ws = generate(workspace(actor: user))
      conv_personal = generate(conversation(actor: user))
      conv_ws = generate(conversation(actor: user, workspace_id: ws.id))

      # billable personal, model A
      create_usage_record(user, model_a, conversation_id: conv_personal.id, billable: true)
      # non-billable: excluded
      create_usage_record(user, model_a, conversation_id: conv_personal.id, billable: false)
      # billable workspace, model B
      create_usage_record(user, model_b, conversation_id: conv_ws.id, billable: true)

      filters = %{
        from: DateTime.add(DateTime.utc_now(), -1, :day),
        to: DateTime.add(DateTime.utc_now(), 1, :day),
        model_name: nil,
        workspace: :all
      }

      assert MessageUsageLog.count(user, filters) == 2
      assert MessageUsageLog.count(user, %{filters | model_name: "Model A"}) == 1
      assert MessageUsageLog.count(user, %{filters | workspace: {:workspace, ws.id}}) == 1
      assert MessageUsageLog.count(user, %{filters | workspace: :personal}) == 1
    end
  end

  describe "summary/2" do
    test "sums tokens and converts USD cost to CHF" do
      user = generate(user())
      model = generate(model())
      conv = generate(conversation(actor: user))

      create_usage_record(user, model,
        conversation_id: conv.id,
        billable: true,
        total_tokens: 200,
        total_cost: Decimal.new("0.10")
      )

      create_usage_record(user, model,
        conversation_id: conv.id,
        billable: true,
        total_tokens: 300,
        total_cost: Decimal.new("0.20")
      )

      filters = %{
        from: DateTime.add(DateTime.utc_now(), -1, :day),
        to: DateTime.add(DateTime.utc_now(), 1, :day),
        model_name: nil,
        workspace: :all
      }

      summary = MessageUsageLog.summary(user, filters)

      assert summary.count == 2
      assert summary.total_tokens == 500
      # FX defaults to 1.0 in test (no rate fetched), so CHF == USD sum.
      assert Decimal.equal?(summary.total_cost_chf, Decimal.new("0.30"))
    end
  end

  describe "page/3 and used_model_names/1" do
    test "returns a page of rows newest-first with the message preloaded" do
      user = generate(user())
      model = generate(model(name: "Zeta"))
      conv = generate(conversation(actor: user))

      for _ <- 1..3,
          do: create_usage_record(user, model, conversation_id: conv.id, billable: true)

      filters = %{
        from: DateTime.add(DateTime.utc_now(), -1, :day),
        to: DateTime.add(DateTime.utc_now(), 1, :day),
        model_name: nil,
        workspace: :all
      }

      %{rows: rows, total_count: total, total_pages: pages} =
        MessageUsageLog.page(user, filters, page: 1, per_page: 2)

      assert total == 3
      assert pages == 2
      assert length(rows) == 2
      assert ["Zeta"] == rows |> Enum.map(& &1.model_name) |> Enum.uniq()

      assert MessageUsageLog.used_model_names(user) == ["Zeta"]
    end
  end

  describe "usage_log action (SPA settings Usage page)" do
    defp run_usage_log(actor, args) do
      Magus.Usage.MessageUsage
      |> Ash.ActionInput.for_action(:usage_log, args, actor: actor)
      |> Ash.run_action!()
    end

    test "returns a JSON-safe payload scoped to the caller" do
      user = generate(user())
      other = generate(user())
      model = generate(model(name: "Alpha"))
      conv = generate(conversation(actor: user))
      other_conv = generate(conversation(actor: other))

      create_usage_record(user, model,
        conversation_id: conv.id,
        billable: true,
        total_tokens: 200,
        total_cost: Decimal.new("0.10")
      )

      create_usage_record(other, model, conversation_id: other_conv.id, billable: true)

      payload = run_usage_log(user, %{range: "30d"})

      assert payload.total_count == 1
      assert payload.total_pages == 1
      assert payload.period_label == "last_30_days"
      assert payload.model_options == ["Alpha"]
      assert payload.summary.count == 1
      assert payload.summary.total_tokens == 200
      # FX defaults to 1.0 in test, and the payload stringifies decimals.
      assert payload.summary.total_cost_chf == "0.1000"

      assert [row] = payload.rows
      assert row.model_name == "Alpha"
      assert row.conversation_id == conv.id
      assert row.cost_chf == "0.1000"
      assert {:ok, _, _} = DateTime.from_iso8601(row.inserted_at)
      assert row.usage_type == "response"
    end

    test "applies model and workspace filters from RPC-style string args" do
      user = generate(user())
      model_a = generate(model(name: "Model A"))
      model_b = generate(model(name: "Model B"))
      ws = generate(workspace(actor: user))
      conv_personal = generate(conversation(actor: user))
      conv_ws = generate(conversation(actor: user, workspace_id: ws.id))

      create_usage_record(user, model_a, conversation_id: conv_personal.id, billable: true)
      create_usage_record(user, model_b, conversation_id: conv_ws.id, billable: true)

      assert run_usage_log(user, %{range: "7d"}).total_count == 2
      assert run_usage_log(user, %{range: "7d", model_name: "Model A"}).total_count == 1
      assert run_usage_log(user, %{range: "7d", workspace: "personal"}).total_count == 1
      assert run_usage_log(user, %{range: "7d", workspace: ws.id}).total_count == 1
      assert run_usage_log(user, %{range: "7d", workspace: "all"}).total_count == 2
    end

    test "is forbidden without an actor" do
      assert_raise Ash.Error.Forbidden, fn ->
        Magus.Usage.MessageUsage
        |> Ash.ActionInput.for_action(:usage_log, %{})
        |> Ash.run_action!()
      end
    end
  end
end
