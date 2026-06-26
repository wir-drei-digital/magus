defmodule Magus.SuperBrain.MigrationTest do
  use ExUnit.Case, async: true

  alias Magus.SuperBrain.Migration

  describe "version constants" do
    test "entity_version/0 returns a positive integer" do
      v = Migration.entity_version()
      assert is_integer(v)
      assert v >= 1
    end

    test "canonical_version/0 returns a positive integer" do
      v = Migration.canonical_version()
      assert is_integer(v)
      assert v >= 1
    end
  end
end
