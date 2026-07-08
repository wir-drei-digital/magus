defmodule Magus.Eval.SuperBrain.FixtureTest do
  use ExUnit.Case, async: true

  alias Magus.Eval.SuperBrain.Fixture

  test "parses entities, edges and sources with defaults" do
    raw = %{
      "entities" => [
        %{
          "key" => "daniel",
          "name" => "Daniel",
          "type" => "person",
          "embedding" => [1, 0, 0],
          "confidence" => 0.9
        }
      ],
      "edges" => [%{"from" => "daniel", "to" => "aurora", "predicate" => "works_on"}],
      "sources" => [
        %{
          "entity" => "daniel",
          "resource_type" => "brain_page",
          "resource_id" => "00000000-0000-4000-8000-000000000001"
        }
      ]
    }

    f = Fixture.parse(raw)

    assert [e] = f.entities
    assert e.key == "daniel"
    assert e.name == "Daniel"
    assert e.normalized_subtype == nil
    assert e.trust_tier == "evidence"
    assert e.embedding == [1, 0, 0]

    assert [edge] = f.edges
    assert edge.from == "daniel" and edge.to == "aurora"
    assert edge.trust_tier == "evidence"

    assert [s] = f.sources
    assert s.entity == "daniel"
    assert s.resource_type == "brain_page"
  end

  test "parses claims and expands basis vectors" do
    f =
      Fixture.parse(%{
        "claims" => [
          %{
            "subject" => "Aurora",
            "predicate" => "occurs_at",
            "object" => "Q3",
            "claim_text" => "Aurora targets Q3.",
            "embedding" => %{"hot" => 2}
          }
        ]
      })

    assert [%{subject: "Aurora"}] = f.claims
    vec = Fixture.expand_basis(%{"hot" => 2})
    assert length(vec) == 1536
    assert Enum.at(vec, 2) == 1.0
  end

  test "claims parse temporal fields and the graph discriminator" do
    raw = %{
      "claims" => [
        %{
          "subject" => "Aurora",
          "predicate" => "occurs_at",
          "object" => "Q4",
          "claim_text" => "Aurora now ships in Q4.",
          "asserted_at" => "2026-06-01T00:00:00Z",
          "valid_from" => "2026-06-01T00:00:00Z",
          "valid_to" => "2026-12-31T00:00:00Z",
          "graph" => "teammate"
        },
        %{
          "subject" => "Aurora",
          "predicate" => "occurs_at",
          "object" => "Q3",
          "claim_text" => "Aurora ships in Q3."
        }
      ]
    }

    fixture = Magus.Eval.SuperBrain.Fixture.parse(raw)
    [with_temporal, without] = fixture.claims

    assert with_temporal.asserted_at == ~U[2026-06-01 00:00:00Z]
    assert with_temporal.valid_from == ~U[2026-06-01 00:00:00Z]
    assert with_temporal.valid_to == ~U[2026-12-31 00:00:00Z]
    assert with_temporal.graph == "teammate"

    assert without.asserted_at == nil
    assert without.valid_from == nil
    assert without.valid_to == nil
    assert without.graph == nil
  end
end
