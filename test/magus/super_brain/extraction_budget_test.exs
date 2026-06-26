defmodule Magus.SuperBrain.ExtractionBudgetTest do
  use Magus.ResourceCase, async: true

  alias Magus.SuperBrain.ExtractionBudget

  describe "atomic_increment" do
    test "increments call count atomically" do
      user = generate(user())
      date = Date.utc_today()

      :ok = ExtractionBudget.atomic_increment(user.id, date, calls: 1, cost_cents: 5)
      :ok = ExtractionBudget.atomic_increment(user.id, date, calls: 1, cost_cents: 3)

      {:ok, budget} = ExtractionBudget.get_for(user.id, date)
      assert budget.llm_call_count == 2
      assert budget.llm_cost_cents == 8
    end
  end

  describe "would_exceed_ceiling?/2" do
    test "returns true when next call would exceed the ceiling" do
      user = generate(user())
      date = Date.utc_today()

      # Pin an explicit ceiling so the assertion is independent of the global
      # @default_daily_ceiling, which production tuning changes over time.
      Ash.create!(ExtractionBudget, %{user_id: user.id, date: date, ceiling_call_count: 2},
        action: :upsert,
        authorize?: false
      )

      :ok = ExtractionBudget.atomic_increment(user.id, date, calls: 1, cost_cents: 0)
      assert ExtractionBudget.would_exceed_ceiling?(user.id, date)
    end

    test "returns false when capacity remains" do
      user = generate(user())
      date = Date.utc_today()
      :ok = ExtractionBudget.atomic_increment(user.id, date, calls: 1, cost_cents: 0)
      refute ExtractionBudget.would_exceed_ceiling?(user.id, date)
    end
  end
end
