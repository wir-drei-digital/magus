defmodule Magus.ReleasePromoteAdminTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  test "promotes an existing user by email" do
    user = generate(user())
    refute user.is_admin

    assert :ok = Magus.Release.promote_admin(user.email |> to_string())
    assert Magus.Accounts.get_user!(user.id, authorize?: false).is_admin
  end

  test "returns not_found for an unknown email" do
    assert {:error, :not_found} = Magus.Release.promote_admin("nobody@example.com")
  end
end
