defmodule Magus.Usage.SponsorOrgTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  setup do
    user = generate(user())
    ensure_workspace_plan(user)

    {:ok, org} =
      Magus.Organizations.create_organization(
        %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
        actor: user
      )

    {:ok, sub} = Magus.Usage.get_user_subscription(user.id, authorize?: false)
    %{user: user, org: org, sub: sub}
  end

  test "set_sponsor_org sets then clears the sponsoring org", %{org: org, sub: sub} do
    {:ok, sponsored} =
      Magus.Usage.set_sponsor_org(sub, %{sponsor_org_id: org.id}, authorize?: false)

    assert sponsored.sponsor_org_id == org.id

    {:ok, reverted} =
      Magus.Usage.set_sponsor_org(sponsored, %{sponsor_org_id: nil}, authorize?: false)

    assert is_nil(reverted.sponsor_org_id)
  end

  test "personal_by_user_id still returns an org-sponsored account", %{
    user: user,
    org: org,
    sub: sub
  } do
    {:ok, _} = Magus.Usage.set_sponsor_org(sub, %{sponsor_org_id: org.id}, authorize?: false)
    {:ok, fetched} = Magus.Usage.get_user_subscription(user.id, authorize?: false)
    assert fetched.sponsor_org_id == org.id
  end
end
