defmodule Magus.Skills.SkillTrustTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  require Ash.Query

  alias Magus.Skills.Approval
  alias Magus.Skills.SkillTrust

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

  test "hard-deleting a trusting user cascades their skill trusts (account deletion path)", %{
    skill: s
  } do
    # A truster who does NOT own the skill, so the only FK exercised by the raw
    # user delete is skill_trusts.user_id (the skill-owner's own resources are
    # cleaned up separately in the real AccountDeletion flow).
    truster = generate(user())
    {:ok, trust} = Magus.Skills.trust_skill(%{skill_id: s.id}, actor: truster)
    assert Approval.trusted?(truster.id, s)

    # Mirrors Magus.Accounts.AccountDeletion.delete_user_row/1, which ends in a
    # raw Ecto delete of the User row. Without the user FK cascade this raises a
    # foreign-key violation and the whole account-deletion transaction aborts.
    assert %Magus.Accounts.User{} = Magus.Repo.delete!(truster)

    assert {:error, _} = Ash.get(SkillTrust, trust.id, authorize?: false)

    assert SkillTrust
           |> Ash.Query.filter(user_id == ^truster.id)
           |> Ash.read!(authorize?: false) == []
  end

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
