defmodule Magus.Accounts.UserContextStrategyTest do
  use Magus.ResourceCase, async: true

  test "context_strategy defaults to nil (inherit) and accepts :rolling/:compact" do
    user = generate(user())
    assert user.context_strategy == nil

    {:ok, updated} =
      user
      |> Ash.Changeset.for_update(:update_settings, %{context_strategy: :compact}, actor: user)
      |> Ash.update()

    assert updated.context_strategy == :compact

    {:ok, rolling} =
      updated
      |> Ash.Changeset.for_update(:update_settings, %{context_strategy: :rolling}, actor: user)
      |> Ash.update()

    assert rolling.context_strategy == :rolling
  end
end
