defmodule Magus.Accounts.UserMemorySettingsTest do
  use Magus.ResourceCase, async: true

  test "profile_enabled defaults to false and the owner can toggle it" do
    user = generate(user())
    assert user.profile_enabled == false

    {:ok, updated} =
      user
      |> Ash.Changeset.for_update(:update_profile_setting, %{profile_enabled: true}, actor: user)
      |> Ash.update()

    assert updated.profile_enabled == true
  end

  test "a different user cannot change someone else's profile_enabled" do
    owner = generate(user())
    other = generate(user())

    assert {:error, _} =
             owner
             |> Ash.Changeset.for_update(:update_profile_setting, %{profile_enabled: true},
               actor: other
             )
             |> Ash.update()
  end
end
