defmodule Magus.SuperBrain.Retrieval.RankerTest do
  use ExUnit.Case, async: true

  alias Magus.SuperBrain.Retrieval.Ranker

  defp candidate(opts) do
    %{
      entity: %{name: opts[:name] || "X", trust_tier: opts[:trust] || :evidence, confidence: 0.8},
      similarity: opts[:sim] || 0.7,
      graph_name: opts[:graph] || "brain:abc",
      graph_weight: opts[:gw] || 1.0,
      source_weight: opts[:sw] || 1.0,
      latest_evidence_at: opts[:age_at] || DateTime.utc_now(),
      neighborhood_support: opts[:nb] || 1.0
    }
  end

  test "all-ones gives score = similarity" do
    c = candidate(sim: 0.8, gw: 1.0, sw: 1.0)
    assert_in_delta Ranker.score(c), 0.8, 0.001
  end

  test "instruction trust tier scales up" do
    c = candidate(sim: 0.5, trust: :instruction)
    assert Ranker.score(c) > 0.5
  end

  test "noise trust tier scales down hard" do
    c = candidate(sim: 0.9, trust: :noise)
    assert Ranker.score(c) < 0.3
  end

  test "graph weight composes multiplicatively" do
    c1 = candidate(sim: 0.5, gw: 1.0)
    c2 = candidate(sim: 0.5, gw: 1.5)
    assert Ranker.score(c2) > Ranker.score(c1)
  end

  test "older evidence decays" do
    fresh = candidate(sim: 0.5, age_at: DateTime.utc_now())
    old = candidate(sim: 0.5, age_at: DateTime.add(DateTime.utc_now(), -180, :day))
    assert Ranker.score(fresh) > Ranker.score(old)
  end
end
