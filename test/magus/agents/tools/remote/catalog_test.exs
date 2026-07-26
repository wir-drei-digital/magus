defmodule Magus.Agents.Tools.Remote.CatalogTest do
  use ExUnit.Case, async: true
  alias Magus.Agents.Tools.Remote.{Catalog, ReadFile}

  test "names lists the known tools" do
    assert Catalog.names() == ["read_file"]
  end

  test "known?/1 distinguishes catalog members" do
    assert Catalog.known?("read_file")
    refute Catalog.known?("exec_command")
  end

  test "resolve maps known names to modules and drops unknown ones" do
    assert Catalog.resolve(["read_file", "rm -rf /"]) == [ReadFile]
    assert Catalog.resolve([]) == []
    assert Catalog.resolve("not-a-list") == []
  end
end
