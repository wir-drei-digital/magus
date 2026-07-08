defmodule Magus.SuperBrain.TemporalTest do
  use ExUnit.Case, async: true

  alias Magus.SuperBrain.Temporal

  @now ~U[2026-07-01 00:00:00Z]

  # Temporal is duck-typed over claim-shaped maps; no DB needed. Explicit ids
  # keep the id tie-break assertable.
  defp claim(overrides) do
    Map.merge(
      %{
        id: "id-#{System.unique_integer([:positive])}",
        subject_key: "aurora",
        predicate: "occurs_at",
        object_key: "q3",
        object_name: "Q3",
        polarity: :affirms,
        asserted_at: ~U[2026-05-01 00:00:00Z],
        valid_from: nil,
        valid_to: nil
      },
      Map.new(overrides)
    )
  end

  defp current_ids(resolved), do: Enum.map(resolved.current, & &1.claim.id)
  defp historic_ids(resolved), do: Enum.map(resolved.historic, & &1.claim.id)

  describe "validity partition" do
    test "expired claims (valid_to before now) go historic with :expired" do
      c = claim(%{id: "a", valid_to: ~U[2026-06-30 00:00:00Z]})
      resolved = Temporal.resolve([c], now: @now)

      assert resolved.current == []
      assert [%{claim: %{id: "a"}, reason: :expired}] = resolved.historic
    end

    test "future claims (valid_from after now) go historic with :future" do
      c = claim(%{id: "a", valid_from: ~U[2026-07-02 00:00:00Z]})
      resolved = Temporal.resolve([c], now: @now)

      assert resolved.current == []
      assert [%{claim: %{id: "a"}, reason: :future}] = resolved.historic
    end

    test "a claim with no validity window is always in-window" do
      resolved = Temporal.resolve([claim(%{id: "a"})], now: @now)
      assert current_ids(resolved) == ["a"]
      assert resolved.historic == []
    end

    test "boundary: valid_to exactly at now is still in-window" do
      c = claim(%{id: "a", valid_to: @now})
      resolved = Temporal.resolve([c], now: @now)
      assert current_ids(resolved) == ["a"]
    end
  end

  describe "value-change supersedence (single-valued predicates)" do
    test "the newer affirms claim wins; the older goes historic :superseded" do
      q3 = claim(%{id: "q3", asserted_at: ~U[2026-05-01 00:00:00Z]})

      q4 =
        claim(%{
          id: "q4",
          object_key: "q4",
          object_name: "Q4",
          asserted_at: ~U[2026-06-01 00:00:00Z]
        })

      resolved = Temporal.resolve([q3, q4], now: @now)

      assert current_ids(resolved) == ["q4"]
      assert [%{claim: %{id: "q3"}, reason: :superseded}] = resolved.historic
    end

    test "a re-assertion of the same object supersedes the older assertion" do
      old = claim(%{id: "old", asserted_at: ~U[2026-05-01 00:00:00Z]})
      new = claim(%{id: "new", asserted_at: ~U[2026-06-01 00:00:00Z]})

      resolved = Temporal.resolve([old, new], now: @now)
      assert current_ids(resolved) == ["new"]
      assert historic_ids(resolved) == ["old"]
    end

    test "multi-valued predicates never supersede by value: both stay current" do
      a = claim(%{id: "a", predicate: "relates_to", object_key: "x"})

      b =
        claim(%{
          id: "b",
          predicate: "relates_to",
          object_key: "y",
          asserted_at: ~U[2026-06-01 00:00:00Z]
        })

      resolved = Temporal.resolve([a, b], now: @now)
      assert Enum.sort(current_ids(resolved)) == ["a", "b"]
      assert resolved.historic == []
    end

    test "a newer negation of one object does NOT supersede an affirmation of another" do
      q4 =
        claim(%{
          id: "q4",
          object_key: "q4",
          object_name: "Q4",
          asserted_at: ~U[2026-05-15 00:00:00Z]
        })

      not_q3 =
        claim(%{
          id: "not-q3",
          polarity: :negates,
          asserted_at: ~U[2026-06-01 00:00:00Z]
        })

      resolved = Temporal.resolve([q4, not_q3], now: @now)
      # Both current: the negation only speaks about Q3, not Q4.
      assert Enum.sort(current_ids(resolved)) == ["not-q3", "q4"]
    end

    test "an expired newer claim does not supersede (resolution is over in-window only)" do
      old = claim(%{id: "old", asserted_at: ~U[2026-05-01 00:00:00Z]})

      newer_expired =
        claim(%{
          id: "newer",
          object_key: "q4",
          asserted_at: ~U[2026-06-01 00:00:00Z],
          valid_to: ~U[2026-06-15 00:00:00Z]
        })

      resolved = Temporal.resolve([old, newer_expired], now: @now)
      assert current_ids(resolved) == ["old"]
      assert [%{claim: %{id: "newer"}, reason: :expired}] = resolved.historic
    end
  end

  describe "polarity-flip supersedence (exact triple, any predicate)" do
    test "a newer negation supersedes the older affirmation of the same triple" do
      yes = claim(%{id: "yes", predicate: "relates_to", asserted_at: ~U[2026-05-01 00:00:00Z]})

      no =
        claim(%{
          id: "no",
          predicate: "relates_to",
          polarity: :negates,
          asserted_at: ~U[2026-06-01 00:00:00Z]
        })

      resolved = Temporal.resolve([yes, no], now: @now)
      assert current_ids(resolved) == ["no"]
      assert [%{claim: %{id: "yes"}, reason: :superseded}] = resolved.historic
    end

    test "a newer affirmation supersedes the older negation of the same triple" do
      no = claim(%{id: "no", polarity: :negates, asserted_at: ~U[2026-05-01 00:00:00Z]})
      yes = claim(%{id: "yes", asserted_at: ~U[2026-06-01 00:00:00Z]})

      resolved = Temporal.resolve([no, yes], now: @now)
      assert current_ids(resolved) == ["yes"]
      assert historic_ids(resolved) == ["no"]
    end
  end

  describe "the newer-than total order" do
    test "equal asserted_at falls back to valid_from; nil valid_from sorts oldest" do
      same = ~U[2026-05-01 00:00:00Z]
      a = claim(%{id: "a", asserted_at: same, valid_from: nil})

      b =
        claim(%{
          id: "b",
          object_key: "q4",
          asserted_at: same,
          valid_from: ~U[2026-05-02 00:00:00Z]
        })

      resolved = Temporal.resolve([a, b], now: @now)
      assert current_ids(resolved) == ["b"]
    end

    test "full tie falls back to id descending" do
      same = ~U[2026-05-01 00:00:00Z]
      a = claim(%{id: "id-a", asserted_at: same})
      b = claim(%{id: "id-b", object_key: "q4", asserted_at: same})

      resolved = Temporal.resolve([a, b], now: @now)
      assert current_ids(resolved) == ["id-b"]
    end

    test "nil asserted_at sorts oldest" do
      a = claim(%{id: "a", asserted_at: nil})
      b = claim(%{id: "b", object_key: "q4", asserted_at: ~U[2026-01-01 00:00:00Z]})

      resolved = Temporal.resolve([a, b], now: @now)
      assert current_ids(resolved) == ["b"]
      assert historic_ids(resolved) == ["a"]
    end
  end

  describe "recency_factor/2" do
    test "age zero gives 1.0" do
      c = claim(%{asserted_at: @now})
      assert_in_delta Temporal.recency_factor(c, @now), 1.0, 1.0e-9
    end

    test "90 days of age gives 0.75 (half of the decaying part)" do
      c = claim(%{asserted_at: DateTime.add(@now, -90, :day)})
      assert_in_delta Temporal.recency_factor(c, @now), 0.75, 1.0e-6
    end

    test "monotonically decreasing with age, floored at 0.5" do
      fresh = claim(%{asserted_at: DateTime.add(@now, -1, :day)})
      old = claim(%{asserted_at: DateTime.add(@now, -400, :day)})
      ancient = claim(%{asserted_at: DateTime.add(@now, -40_000, :day)})

      f = Temporal.recency_factor(fresh, @now)
      o = Temporal.recency_factor(old, @now)
      a = Temporal.recency_factor(ancient, @now)

      assert f > o
      assert o > a
      assert a >= 0.5
      assert f <= 1.0
    end

    test "nil asserted_at takes the floor 0.5" do
      assert Temporal.recency_factor(claim(%{asserted_at: nil}), @now) == 0.5
    end

    test "a future asserted_at clamps age to zero (factor 1.0)" do
      c = claim(%{asserted_at: DateTime.add(@now, 10, :day)})
      assert_in_delta Temporal.recency_factor(c, @now), 1.0, 1.0e-9
    end
  end

  describe "resolve/2 output shape" do
    test "empty input yields empty partitions" do
      assert Temporal.resolve([], now: @now) == %{current: [], historic: []}
    end

    test "current entries carry score_factors with the recency factor" do
      resolved = Temporal.resolve([claim(%{id: "a", asserted_at: @now})], now: @now)
      assert [%{claim: %{id: "a"}, score_factors: %{recency: r}}] = resolved.current
      assert_in_delta r, 1.0, 1.0e-9
    end
  end
end
