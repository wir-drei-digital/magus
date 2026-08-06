defmodule Magus.Chat.Workers.SweepUsageReconciliationTest do
  use Magus.DataCase, async: false
  use Oban.Testing, repo: Magus.Repo

  import Magus.Generators
  require Ash.Query

  alias Magus.Chat.Workers.SweepUsageReconciliation
  alias Magus.Usage.MessageUsage

  setup do
    user = generate(user())
    model = generate(model())

    # The charge path accrues to the period accumulator, which needs an
    # active subscription.
    plan = generate(usage_plan())

    {:ok, _} =
      Magus.Usage.create_user_subscription(
        %{user_id: user.id, usage_plan_id: plan.id, status: :active},
        authorize?: false
      )

    %{user: user, model: model}
  end

  defp usage_row(ctx, status, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          user_id: ctx.user.id,
          model_id: ctx.model.id,
          model_name: ctx.model.name,
          usage_type: :response,
          prompt_tokens: 0,
          completion_tokens: 0,
          total_tokens: 0,
          total_cost: Decimal.new("0.01"),
          billable: true,
          provider_generation_id: "gen-#{System.unique_integer([:positive])}",
          reconciliation_status: status
        },
        overrides
      )

    Ash.create!(MessageUsage, attrs, action: :create, authorize?: false)
  end

  defp reload!(row) do
    Ash.get!(MessageUsage, row.id, authorize?: false)
  end

  test "unavailable rows inside the window flip to pending and re-enqueue", ctx do
    row = usage_row(ctx, :unavailable)

    assert :ok = perform_job(SweepUsageReconciliation, %{})

    assert reload!(row).reconciliation_status == :pending

    assert_enqueued(
      worker: Magus.Chat.Workers.ReconcileOpenRouterUsage,
      args: %{usage_id: row.id}
    )
  end

  test "unavailable rows without a generation id are left alone", ctx do
    row = usage_row(ctx, :unavailable, %{provider_generation_id: nil})

    assert :ok = perform_job(SweepUsageReconciliation, %{})

    assert reload!(row).reconciliation_status == :unavailable
  end

  test "reconciled_uncharged rows are charged and flipped to reconciled", ctx do
    row = usage_row(ctx, :reconciled_uncharged)

    assert :ok = perform_job(SweepUsageReconciliation, %{})

    assert reload!(row).reconciliation_status == :reconciled
  end

  test "terminal rows are untouched", ctx do
    reconciled = usage_row(ctx, :reconciled)
    not_required = usage_row(ctx, :not_required)

    assert :ok = perform_job(SweepUsageReconciliation, %{})

    assert reload!(reconciled).reconciliation_status == :reconciled
    assert reload!(not_required).reconciliation_status == :not_required
  end
end
