defmodule Magus.Organizations.OrganizationTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Organizations

  describe "create organization" do
    test "creates an org with defaults" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, org} =
        Organizations.create_organization(%{name: "Acme", slug: "acme"}, actor: user)

      assert org.name == "Acme"
      assert org.slug == "acme"
      assert org.owner_id == user.id
      assert org.billing_interval == :monthly
      assert org.billing_status == :active
      assert org.stripe_customer_id == nil
    end

    test "slug must be unique" do
      user = generate(user())
      ensure_workspace_plan(user)
      {:ok, _} = Organizations.create_organization(%{name: "A", slug: "dupe"}, actor: user)

      other = generate(user())
      ensure_workspace_plan(other)

      assert {:error, %Ash.Error.Invalid{}} =
               Organizations.create_organization(%{name: "B", slug: "dupe"}, actor: other)
    end
  end
end
