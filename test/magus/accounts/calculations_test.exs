defmodule Magus.Accounts.CalculationsTest do
  @moduledoc """
  Tests for Ash calculations in the Accounts domain.
  """
  use Magus.ResourceCase, async: true

  describe "User.name_or_email" do
    test "returns display_name when set" do
      user = generate(user(display_name: "John Doe"))

      {:ok, loaded} = Ash.load(user, :name_or_email, actor: user)

      assert loaded.name_or_email == "John Doe"
    end

    test "returns name when display_name is nil" do
      user = generate(user(name: "Jane Smith"))

      {:ok, loaded} = Ash.load(user, :name_or_email, actor: user)

      assert loaded.name_or_email == "Jane Smith"
    end

    test "returns email when no names are set" do
      # Create user then clear names to test email fallback
      user = generate(user())

      {:ok, user} =
        user
        |> Ash.Changeset.for_update(:update_settings, %{})
        |> Ash.Changeset.force_change_attribute(:name, nil)
        |> Ash.update(authorize?: false)

      {:ok, loaded} = Ash.load(user, :name_or_email, actor: user)

      # Email should be returned as string
      assert loaded.name_or_email != nil
      assert String.contains?(loaded.name_or_email, "@")
    end
  end
end
