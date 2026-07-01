defmodule Magus.Skills.Import.UnpackTest do
  use ExUnit.Case, async: true

  alias Magus.Skills.Import.Unpack

  # Build an in-memory zip from a list of {path_charlist, content_binary}.
  defp zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_name, bytes}} = :zip.create(~c"bundle.zip", files, [:memory])
    bytes
  end

  test "unpacks SKILL.md and bundle files" do
    bytes = zip([{"SKILL.md", "---\nname: x\n---\nbody"}, {"scripts/run.py", "print(1)"}])
    assert {:ok, %{skill_md: md, files: files}} = Unpack.unpack(bytes)
    assert md =~ "name: x"
    assert {"scripts/run.py", "print(1)"} in files
    refute Enum.any?(files, fn {p, _} -> p == "SKILL.md" end)
  end

  test "rejects a missing SKILL.md" do
    bytes = zip([{"scripts/run.py", "print(1)"}])
    assert {:error, :missing_skill_md} = Unpack.unpack(bytes)
  end

  test "rejects path traversal entries" do
    bytes = zip([{"SKILL.md", "x"}, {"foo/bar/../../evil.sh", "rm -rf"}])
    assert {:error, :unsafe_path} = Unpack.unpack(bytes)
  end

  test "rejects invalid zip bytes" do
    assert {:error, :invalid_zip} = Unpack.unpack("not a zip")
  end

  test "strips a shared top-level directory (folder-wrapped zip)" do
    bytes =
      zip([
        {"my-skill/SKILL.md", "---\nname: x\n---\nbody"},
        {"my-skill/scripts/run.py", "print(1)"}
      ])

    assert {:ok, %{skill_md: md, files: files}} = Unpack.unpack(bytes)
    assert md =~ "name: x"
    assert {"scripts/run.py", "print(1)"} in files
  end

  test "does not strip when entries share no single top-level directory" do
    bytes = zip([{"SKILL.md", "---\nname: x\n---\nbody"}, {"scripts/run.py", "print(1)"}])
    assert {:ok, %{skill_md: md, files: files}} = Unpack.unpack(bytes)
    assert md =~ "name: x"
    assert {"scripts/run.py", "print(1)"} in files
  end
end
