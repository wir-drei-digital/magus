defmodule Magus.Chat.ModelOwnershipTest do
  use Magus.DataCase, async: false
  import Magus.Generators

  setup do
    Magus.DataCase.clear_catalog!()
    %{user: generate(user()), other: generate(user())}
  end

  # Seed owned/global rows directly (create_owned is Task 4). authorize?: false
  # because there is no Model authorizer in 2b-1; scoping is via the read filter.
  defp owned_model!(owner, key) do
    Magus.Chat.Model
    |> Ash.Changeset.for_create(:create, %{name: key, key: key, context_window: 1000})
    |> Ash.Changeset.force_change_attribute(:owner_user_id, owner.id)
    |> Ash.Changeset.force_change_attribute(:api_provider, :byok)
    |> Ash.create!(authorize?: false)
  end

  defp global_model!(key) do
    Magus.Chat.Model
    |> Ash.Changeset.for_create(:create, %{name: key, key: key, context_window: 1000})
    |> Ash.create!(authorize?: false)
  end

  test "api_provider accepts :byok", %{user: user} do
    m = owned_model!(user, "u_a:x")
    assert m.api_provider == :byok
    assert m.owner_user_id == user.id
  end

  test "list_active returns global plus own, never others' owned", %{user: user, other: other} do
    global_model!("openrouter:g/1")
    owned_model!(user, "u_b:mine")
    owned_model!(other, "u_c:theirs")

    keys = Magus.Chat.list_active_models!(actor: user) |> Enum.map(& &1.key)

    assert "openrouter:g/1" in keys
    assert "u_b:mine" in keys
    refute "u_c:theirs" in keys
  end

  test "list_active with no actor returns global only", %{user: user} do
    global_model!("openrouter:g/2")
    owned_model!(user, "u_d:priv")

    keys = Magus.Chat.list_active_models!(authorize?: false) |> Enum.map(& &1.key)
    assert "openrouter:g/2" in keys
    refute "u_d:priv" in keys
  end
end
