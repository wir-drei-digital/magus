defmodule Magus.SuperBrain.DossierTest do
  use ExUnit.Case, async: true

  alias Magus.SuperBrain.Dossier

  defp claim(overrides) do
    Map.merge(
      %{
        subject_key: "aurora",
        subject_name: "Aurora",
        object_key: "q3",
        object_name: "Q3",
        predicate: "occurs_at",
        polarity: :affirms,
        claim_text: "Aurora targets Q3.",
        trust_tier: :evidence,
        asserted_at: ~U[2026-06-01 00:00:00Z]
      },
      overrides
    )
  end

  test "splits facts (subject) from referenced_by (object) and dedups texts per group" do
    d = Dossier.build("aurora", [claim(%{}), claim(%{claim_text: "Aurora targets Q3."})])
    assert [%{predicate: "occurs_at", texts: ["Aurora targets Q3."], evidence_count: 2}] = d.facts
    assert d.referenced_by == []
  end

  test "flags opposite-polarity claims on the same triple as a conflict" do
    d =
      Dossier.build("aurora", [
        claim(%{polarity: :affirms, claim_text: "Aurora ships in Q3."}),
        claim(%{polarity: :negates, claim_text: "Aurora does not ship in Q3."})
      ])

    assert length(d.conflicts) == 1
  end

  test "orders groups by latest asserted_at descending" do
    d =
      Dossier.build("aurora", [
        claim(%{object_key: "q3", object_name: "Q3", asserted_at: ~U[2026-05-01 00:00:00Z]}),
        claim(%{object_key: "q4", object_name: "Q4", asserted_at: ~U[2026-06-01 00:00:00Z]})
      ])

    assert [%{other_key: "q4"}, %{other_key: "q3"}] = d.facts
  end

  describe "current-vs-historic split" do
    test "facts come from current claims; historic land in history with status" do
      current =
        claim(%{
          object_key: "q4",
          object_name: "Q4",
          claim_text: "Aurora now ships in Q4.",
          asserted_at: ~U[2026-06-01 00:00:00Z],
          status: :current
        })

      superseded =
        claim(%{
          claim_text: "Aurora ships in Q3.",
          asserted_at: ~U[2026-05-01 00:00:00Z],
          status: :superseded
        })

      d = Dossier.build("aurora", [current, superseded])

      assert [%{other_name: "Q4"}] = d.facts
      assert [%{object_name: "Q3", status: :superseded, predicate: "occurs_at"}] = d.history
    end

    test "expired claims carry the :expired status in history" do
      expired =
        claim(%{
          claim_text: "Aurora uses OldVendor.",
          predicate: "relates_to",
          object_key: "oldvendor",
          object_name: "OldVendor",
          status: :expired
        })

      d = Dossier.build("aurora", [expired])

      assert d.facts == []
      assert [%{status: :expired, object_name: "OldVendor"}] = d.history
    end

    test "history is ordered newest-first by asserted_at" do
      older =
        claim(%{
          object_name: "Q2",
          object_key: "q2",
          asserted_at: ~U[2026-04-01 00:00:00Z],
          status: :superseded
        })

      newer =
        claim(%{
          object_name: "Q3",
          object_key: "q3",
          asserted_at: ~U[2026-05-01 00:00:00Z],
          status: :superseded
        })

      d = Dossier.build("aurora", [older, newer])
      assert Enum.map(d.history, & &1.object_name) == ["Q3", "Q2"]
    end

    test "untagged claims default to current (backward compatible) and history is empty" do
      d = Dossier.build("aurora", [claim(%{})])
      assert [_] = d.facts
      assert d.history == []
    end

    test "conflicts stay computed over all claims, including historic" do
      yes = claim(%{polarity: :affirms, claim_text: "Aurora ships in Q3.", status: :superseded})

      no =
        claim(%{
          polarity: :negates,
          claim_text: "Aurora does not ship in Q3.",
          asserted_at: ~U[2026-06-15 00:00:00Z],
          status: :current
        })

      d = Dossier.build("aurora", [yes, no])
      assert length(d.conflicts) == 1
    end
  end
end
