defmodule Magus.SuperBrain.OntologyTest do
  use ExUnit.Case, async: true
  alias Magus.SuperBrain.Ontology

  describe "entity_types/0" do
    test "returns the canonical seed types" do
      types = Ontology.entity_types()
      assert :person in types
      assert :project in types
      assert :date in types
      assert :decision in types
      # iter5 Task 3.5: 12 original + 5 new = 17 total.
      assert length(types) == 17
    end

    test "includes the iter5 entity types" do
      types = Ontology.entity_types()

      for new_type <- [:role, :measurement, :goal, :resource, :identifier] do
        assert new_type in types, "expected #{new_type} in entity_types/0"
      end
    end
  end

  describe "valid_entity_type?/1" do
    test "accepts canonical types" do
      assert Ontology.valid_entity_type?(:person)
      assert Ontology.valid_entity_type?(:concept)
    end

    test "accepts the iter5 entity types" do
      for new_type <- [:role, :measurement, :goal, :resource, :identifier] do
        assert Ontology.valid_entity_type?(new_type), "expected #{new_type} to be valid"
      end
    end

    test "rejects unknown types" do
      refute Ontology.valid_entity_type?(:wizard)
      refute Ontology.valid_entity_type?("person")
    end
  end

  describe "valid_predicate?/1" do
    test "accepts canonical predicates" do
      for p <- [
            :relates_to,
            :mentions,
            :supports,
            :contradicts,
            :derived_from,
            :updates,
            :extends,
            :derives
          ] do
        assert Ontology.valid_predicate?(p), "expected #{p} to be valid"
      end
    end

    test "accepts the iter5 temporal predicates" do
      for p <- [:precedes, :follows, :occurs_at] do
        assert Ontology.valid_predicate?(p), "expected #{p} to be valid"
      end
    end

    test "accepts the iter5 identity predicates" do
      for p <- [:is_a, :instance_of, :part_of] do
        assert Ontology.valid_predicate?(p), "expected #{p} to be valid"
      end
    end

    test "accepts the iter5 spatial predicate" do
      assert Ontology.valid_predicate?(:located_in)
    end

    test "accepts the iter5 causal predicates" do
      for p <- [:causes, :prevents, :enables] do
        assert Ontology.valid_predicate?(p), "expected #{p} to be valid"
      end
    end

    test "free-form predicates are stored but flagged" do
      # Pre-create the atom so production-like input still works for known terms.
      # Ontology never creates atoms from unbounded input (atom-exhaustion DoS),
      # so callers must reference the atom literal somewhere first.
      _ = :works_on
      assert Ontology.classify_predicate("works_on") == {:freeform, :works_on}
      assert Ontology.classify_predicate(:relates_to) == {:canonical, :relates_to}

      # An unknown string stays a binary - we do NOT create new atoms.
      unique =
        "definitely_not_an_atom_yet_xyz_#{System.unique_integer([:positive])}"

      assert {:freeform, ^unique} = Ontology.classify_predicate(unique)
    end
  end

  describe "canonical_predicates/0" do
    test "iter5 total is 18 (8 original + 10 new)" do
      assert length(Ontology.canonical_predicates()) == 18
    end
  end

  describe "compute_trust_tier/2" do
    test "instruction when confidence high AND source explicit" do
      assert Ontology.compute_trust_tier(0.95, source: :user_curated) == :instruction
      assert Ontology.compute_trust_tier(0.95, source: :memory_explicit) == :instruction
    end

    test "evidence for normal LLM extraction" do
      assert Ontology.compute_trust_tier(0.7, source: :llm_extract) == :evidence
      assert Ontology.compute_trust_tier(0.4, source: :llm_extract) == :evidence
    end

    test "noise for low confidence or repeatedly contradicted" do
      assert Ontology.compute_trust_tier(0.15, source: :llm_extract) == :noise

      assert Ontology.compute_trust_tier(0.6,
               source: :llm_extract,
               contradiction_count: 3
             ) == :noise
    end
  end

  describe "trust_tier_multiplier/1" do
    test "returns scoring multipliers" do
      assert Ontology.trust_tier_multiplier(:instruction) == 1.5
      assert Ontology.trust_tier_multiplier(:evidence) == 1.0
      assert Ontology.trust_tier_multiplier(:noise) == 0.2
    end
  end

  describe "contradicting_predicates/0" do
    test "supports <-> contradicts pair (legacy)" do
      pairs = Ontology.contradicting_predicates()
      assert Map.get(pairs, "supports") == "contradicts"
      assert Map.get(pairs, "contradicts") == "supports"
    end

    test "precedes <-> follows pair (iter5 temporal)" do
      pairs = Ontology.contradicting_predicates()
      assert Map.get(pairs, "precedes") == "follows"
      assert Map.get(pairs, "follows") == "precedes"
    end

    test "causes <-> prevents pair (iter5 causal)" do
      pairs = Ontology.contradicting_predicates()
      assert Map.get(pairs, "causes") == "prevents"
      assert Map.get(pairs, "prevents") == "causes"
    end
  end

  describe "single_valued_predicates/0 and single_valued_predicate?/1" do
    test "the curated set is seeded with occurs_at only, as strings" do
      assert Magus.SuperBrain.Ontology.single_valued_predicates() == ["occurs_at"]
    end

    test "accepts binaries (how Claim stores predicate) and atoms (ontology lists)" do
      assert Magus.SuperBrain.Ontology.single_valued_predicate?("occurs_at")
      assert Magus.SuperBrain.Ontology.single_valued_predicate?(:occurs_at)
      refute Magus.SuperBrain.Ontology.single_valued_predicate?("relates_to")
      refute Magus.SuperBrain.Ontology.single_valued_predicate?(:relates_to)
    end
  end
end
