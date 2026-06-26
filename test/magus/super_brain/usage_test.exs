defmodule Magus.SuperBrain.UsageTest do
  use Magus.ResourceCase, async: true

  alias Magus.SuperBrain.Usage

  describe "write_message_usage/3" do
    test "creates a MessageUsage row with the given usage_type" do
      user = generate(user())

      usage = %Usage{
        model_name: "anthropic:claude-haiku-4-5",
        prompt_tokens: 100,
        completion_tokens: 50,
        total_tokens: 150,
        cached_tokens: 0,
        input_cost: Decimal.new("0.001"),
        output_cost: Decimal.new("0.002"),
        total_cost: Decimal.new("0.003")
      }

      assert {:ok, row} = Usage.write_message_usage(usage, user.id, :super_brain_extraction)
      assert row.usage_type == :super_brain_extraction
      assert row.user_id == user.id
      assert row.model_name == "anthropic:claude-haiku-4-5"
      assert row.prompt_tokens == 100
      assert row.completion_tokens == 50
      assert row.total_tokens == 150
      assert Decimal.equal?(row.total_cost, Decimal.new("0.003"))
      # Background extraction is a system operation: never counts against limits.
      refute row.billable
    end

    test "handles a nil model_id gracefully (model not in catalog)" do
      user = generate(user())

      usage = %Usage{
        model_name: "some-unknown-model-#{System.unique_integer([:positive])}",
        prompt_tokens: 10,
        completion_tokens: 5,
        total_tokens: 15,
        cached_tokens: 0,
        input_cost: Decimal.new("0"),
        output_cost: Decimal.new("0"),
        total_cost: Decimal.new("0")
      }

      assert {:ok, row} = Usage.write_message_usage(usage, user.id, :embedding)
      assert row.usage_type == :embedding
      assert row.model_name == usage.model_name
      refute row.billable
      # model_id may be nil if the model is not in the catalog
    end
  end
end
