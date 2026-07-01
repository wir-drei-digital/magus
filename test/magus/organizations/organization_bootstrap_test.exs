defmodule Magus.Organizations.OrganizationBootstrapTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Organizations

  test "creating an org auto-creates an owner member" do
    user = generate(user())
    ensure_workspace_plan(user)

    {:ok, org} = Organizations.create_organization(%{name: "Boot", slug: "boot"}, actor: user)
    {:ok, members} = Organizations.list_org_members(org.id, actor: user)

    assert length(members) == 1
    [owner] = members
    assert owner.user_id == user.id
    assert owner.role == :owner
    assert owner.status == :active
    assert owner.invite_email == to_string(user.email)
  end

  test "creator can read their own org after creation (read policy satisfiable)" do
    user = generate(user())
    ensure_workspace_plan(user)
    {:ok, org} = Organizations.create_organization(%{name: "Read", slug: "read-me"}, actor: user)
    assert {:ok, fetched} = Organizations.get_organization(org.id, actor: user)
    assert fetched.id == org.id
  end
end
