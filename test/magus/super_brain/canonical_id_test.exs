defmodule Magus.SuperBrain.CanonicalIdTest do
  @moduledoc """
  Tests for `Magus.SuperBrain.CanonicalId`, the shared
  `:CanonicalEntity.id` formula. The formula MUST be deterministic for
  a given `(super_graph, type, normalized_subtype, name)` tuple. The
  normalized name (case- and whitespace-insensitive) IS part of the hash
  key so that distinct entities of the same `(type, normalized_subtype)`
  do not collapse into a single canonical.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Magus.SuperBrain.CanonicalId

  describe "for/4 determinism" do
    test "same inputs produce the same id" do
      id1 = CanonicalId.for("super:user:u1", "person", "user", "Daniel")
      id2 = CanonicalId.for("super:user:u1", "person", "user", "Daniel")
      assert id1 == id2
    end

    test "returns a 32-char lowercase hex string" do
      id = CanonicalId.for("super:user:u1", "person", "user", "Daniel")
      assert String.length(id) == 32
      assert id == String.downcase(id)
      assert Regex.match?(~r/\A[0-9a-f]+\z/, id)
    end

    test "name distinguishes the id (case- and whitespace-insensitive)" do
      daniel = CanonicalId.for("super:user:u1", "person", "user", "Daniel")
      jared = CanonicalId.for("super:user:u1", "person", "user", "Jared")
      daniel_messy = CanonicalId.for("super:user:u1", "person", "user", "  daniel ")
      no_name = CanonicalId.for("super:user:u1", "person", "user", nil)

      # distinct names -> distinct canonicals (the over-collapse fix: every
      # entity of a type no longer folds into one node)
      refute daniel == jared
      # the name is normalized, so casing / surrounding whitespace do not split
      assert daniel == daniel_messy
      # a missing name is its own bucket, distinct from any real name
      refute daniel == no_name
    end

    test "differs across super_graph" do
      a = CanonicalId.for("super:user:u1", "person", "user", "Daniel")
      b = CanonicalId.for("super:user:u2", "person", "user", "Daniel")
      refute a == b
    end

    test "differs across type" do
      a = CanonicalId.for("super:user:u1", "person", "user", "Daniel")
      b = CanonicalId.for("super:user:u1", "organization", "user", "Daniel")
      refute a == b
    end

    test "differs across normalized_subtype" do
      a = CanonicalId.for("super:user:u1", "person", "user", "Daniel")
      b = CanonicalId.for("super:user:u1", "person", "character", "Daniel")
      refute a == b
    end

    test "nil normalized_subtype hashes as the __none__ sentinel" do
      a = CanonicalId.for("super:user:u1", "person", nil, "Daniel")
      b = CanonicalId.for("super:user:u1", "person", "__none__", "Daniel")
      assert a == b
    end

    test "nil normalized_subtype does NOT collide with empty string" do
      # The empty string is a valid normalized_subtype value in some
      # future schema; __none__ must stay distinct so a known-unknown
      # bucket does not collapse with one of the real-subtype buckets.
      a = CanonicalId.for("super:user:u1", "person", nil, "Daniel")
      b = CanonicalId.for("super:user:u1", "person", "", "Daniel")
      refute a == b
    end

    test "atom type is treated equivalently to its string form" do
      a = CanonicalId.for("super:user:u1", :person, "user", "Daniel")
      b = CanonicalId.for("super:user:u1", "person", "user", "Daniel")
      assert a == b
    end
  end

  property "for/4 is deterministic for any inputs" do
    check all(
            super_graph <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32),
            type <- StreamData.string(:alphanumeric, max_length: 24),
            nsubtype <-
              StreamData.one_of([
                StreamData.constant(nil),
                StreamData.string(:alphanumeric, max_length: 24)
              ]),
            name <-
              StreamData.one_of([
                StreamData.constant(nil),
                StreamData.string(:printable, max_length: 64)
              ])
          ) do
      a = CanonicalId.for(super_graph, type, nsubtype, name)
      b = CanonicalId.for(super_graph, type, nsubtype, name)
      assert a == b
      assert String.length(a) == 32
    end
  end

  property "for/4 normalizes the name (case- and whitespace-insensitive)" do
    check all(
            super_graph <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32),
            type <- StreamData.string(:alphanumeric, max_length: 24),
            nsubtype <-
              StreamData.one_of([
                StreamData.constant(nil),
                StreamData.string(:alphanumeric, max_length: 24)
              ]),
            name <- StreamData.string(:alphanumeric, min_length: 1, max_length: 64)
          ) do
      a = CanonicalId.for(super_graph, type, nsubtype, name)
      b = CanonicalId.for(super_graph, type, nsubtype, "  " <> String.upcase(name) <> "  ")
      assert a == b
    end
  end
end
