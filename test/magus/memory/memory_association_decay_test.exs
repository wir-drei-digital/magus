defmodule Magus.Memory.MemoryAssociationDecayTest do
  use ExUnit.Case, async: true

  alias Magus.Memory.MemoryAssociation

  @now ~U[2026-07-04 12:00:00.000000Z]

  defp assoc(weight, days_ago) do
    %{weight: weight, last_reinforced_at: DateTime.add(@now, -days_ago * 86_400, :second)}
  end

  test "freshly reinforced weight is undecayed" do
    assert_in_delta MemoryAssociation.effective_weight(assoc(0.8, 0), @now), 0.8, 0.001
  end

  test "weight halves after one 30-day half-life" do
    assert_in_delta MemoryAssociation.effective_weight(assoc(0.8, 30), @now), 0.4, 0.001
  end

  test "weight quarters after two half-lives" do
    assert_in_delta MemoryAssociation.effective_weight(assoc(0.8, 60), @now), 0.2, 0.001
  end

  test "future last_reinforced_at (clock skew) never amplifies above stored weight" do
    assert MemoryAssociation.effective_weight(assoc(0.8, -1), @now) <= 0.8
  end
end
