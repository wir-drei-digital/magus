defmodule Magus.SuperBrain.GraphWeightTest do
  use Magus.ResourceCase, async: true

  alias Magus.SuperBrain.GraphWeight

  describe "weight_for/2" do
    test "returns user override when present" do
      user = generate(user())

      Ash.create!(
        GraphWeight,
        %{scope: :user, scope_id: user.id, graph_pattern: "brain:*", weight: 2.5},
        authorize?: false
      )

      assert GraphWeight.weight_for("brain:abc", user) == 2.5
    end

    test "falls back to default when no override" do
      user = generate(user())
      assert GraphWeight.weight_for("brain:abc", user) == 1.5
      assert GraphWeight.weight_for("files:user:#{user.id}", user) == 1.0
    end

    test "literal-prefix patterns do not match arbitrary chars" do
      user = generate(user())

      Ash.create!(
        GraphWeight,
        %{scope: :user, scope_id: user.id, graph_pattern: "brain.abc", weight: 99.0},
        authorize?: false
      )

      # "brain.abc" is a literal, so "brainXabc" must NOT match
      refute GraphWeight.weight_for("brainXabc", user) == 99.0
      # And exact match should still work
      assert GraphWeight.weight_for("brain.abc", user) == 99.0
    end

    test "malformed pattern is ignored, falls back to default" do
      user = generate(user())

      Ash.create!(
        GraphWeight,
        %{scope: :user, scope_id: user.id, graph_pattern: "(foo", weight: 99.0},
        authorize?: false
      )

      # Malformed regex should not crash; resolution falls back to defaults
      assert GraphWeight.weight_for("brain:abc", user) == 1.5
    end
  end
end
