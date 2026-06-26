defmodule Magus.Accounts.PoliciesTest do
  @moduledoc """
  Tests for authorization policies in the Accounts domain.
  """
  use Magus.ResourceCase, async: true

  alias Magus.Accounts

  describe "User policies" do
    test "user can read their own profile" do
      user = generate(user())

      {:ok, found} = Accounts.get_user(user.id, actor: user)
      assert found.id == user.id
    end

    test "user can update their own settings" do
      user = generate(user())

      {:ok, updated} =
        Accounts.update_user_settings(user, %{display_name: "New Name"}, actor: user)

      assert updated.display_name == "New Name"
    end

    test "user cannot update another users settings" do
      user1 = generate(user())
      user2 = generate(user())

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.update_user_settings(user1, %{display_name: "Hacked"}, actor: user2)
    end
  end
end
