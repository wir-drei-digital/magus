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
end
