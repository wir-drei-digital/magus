defmodule Magus.Accounts.UserImageSettingsTest do
  use Magus.ResourceCase, async: true

  describe "update_image_generation_settings" do
    test "persists valid settings on user" do
      user = generate(user())

      settings = %{"aspect_ratio" => "9:16", "image_size" => "4K"}

      {:ok, updated} =
        Magus.Accounts.update_image_generation_settings(
          user,
          %{image_generation_settings: settings},
          actor: user
        )

      assert updated.image_generation_settings == settings
    end

    test "sanitizes invalid values" do
      user = generate(user())

      settings = %{"aspect_ratio" => "bad", "image_size" => "10K", "injected" => "data"}

      {:ok, updated} =
        Magus.Accounts.update_image_generation_settings(
          user,
          %{image_generation_settings: settings},
          actor: user
        )

      assert updated.image_generation_settings == %{}
    end

    test "rejects update from a different user" do
      user = generate(user())
      other_user = generate(user())

      settings = %{"aspect_ratio" => "1:1", "image_size" => "1K"}

      assert {:error, %Ash.Error.Forbidden{}} =
               Magus.Accounts.update_image_generation_settings(
                 user,
                 %{image_generation_settings: settings},
                 actor: other_user
               )
    end
  end
end
