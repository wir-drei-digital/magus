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
end
