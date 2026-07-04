defmodule Magus.Skills.SkillTrustTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  alias Magus.Skills.Approval

  setup do
    user = generate(user())

    bytes =
      build_zip([
        {"SKILL.md", "---\nname: trust-skill\ndescription: d\n---\nb"},
        {"scripts/go.py", "x=1"}
      ])

    {:ok, skill} = Magus.Skills.Import.import_bundle(bytes, actor: user)
    %{user: user, skill: skill}
  end

  test "not trusted by default", %{user: u, skill: s} do
    refute Approval.trusted?(u.id, s)
  end

  test "trust then trusted? true; a sha change stales it", %{user: u, skill: s} do
    {:ok, _} = Magus.Skills.trust_skill(%{skill_id: s.id}, actor: u)
    assert Approval.trusted?(u.id, s)

    stale = %{s | bundle_sha: "deadbeef"}
    refute Approval.trusted?(u.id, stale)
  end

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
