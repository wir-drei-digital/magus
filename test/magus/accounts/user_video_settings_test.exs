defmodule Magus.Accounts.UserVideoSettingsTest do
  use Magus.ResourceCase, async: true

  describe "update_video_generation_settings" do
    test "persists valid settings on user" do
      user = generate(user())

      settings = %{
        "aspect_ratio" => "9:16",
        "duration" => "10",
        "resolution" => "720p",
        "generate_audio" => false
      }

      {:ok, updated} =
        Magus.Accounts.update_video_generation_settings(
          user,
          %{video_generation_settings: settings},
          actor: user
        )

      assert updated.video_generation_settings == settings
    end

    test "sanitizes invalid values" do
      user = generate(user())

      settings = %{"aspect_ratio" => "bad", "duration" => "99", "injected" => "data"}

      {:ok, updated} =
        Magus.Accounts.update_video_generation_settings(
          user,
          %{video_generation_settings: settings},
          actor: user
        )

      assert updated.video_generation_settings == %{}
    end

    test "rejects update from a different user" do
      user = generate(user())
      other_user = generate(user())

      settings = %{"aspect_ratio" => "16:9", "duration" => "5"}

      assert {:error, %Ash.Error.Forbidden{}} =
               Magus.Accounts.update_video_generation_settings(
                 user,
                 %{video_generation_settings: settings},
                 actor: other_user
               )
    end
  end
end
