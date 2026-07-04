defmodule Magus.Skills.SkillBundleShaTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  test "import records bundle_sha equal to the zip sha256" do
    user = generate(user())

    bytes =
      build_zip([
        {"SKILL.md", "---\nname: sha-skill\ndescription: d\n---\nbody"},
        {"scripts/go.py", "print(1)"}
      ])

    expected = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    {:ok, skill} = Magus.Skills.Import.import_bundle(bytes, actor: user)

    assert skill.bundle_sha == expected
  end

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
