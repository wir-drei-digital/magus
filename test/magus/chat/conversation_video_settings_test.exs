defmodule Magus.Chat.ConversationVideoSettingsTest do
  use Magus.ResourceCase, async: true

  describe "update_video_generation_settings" do
    test "persists valid settings on conversation" do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      settings = %{
        "aspect_ratio" => "16:9",
        "duration" => "5",
        "resolution" => "1080p",
        "generate_audio" => true
      }

      {:ok, updated} =
        Magus.Chat.update_video_generation_settings(
          conversation,
          %{video_generation_settings: settings},
          actor: user
        )

      assert updated.video_generation_settings == settings
    end

    test "sanitizes invalid values" do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      settings = %{"aspect_ratio" => "5:4", "duration" => "15", "extra" => "bad"}

      {:ok, updated} =
        Magus.Chat.update_video_generation_settings(
          conversation,
          %{video_generation_settings: settings},
          actor: user
        )

      assert updated.video_generation_settings == %{}
    end

    test "keeps valid values and drops invalid ones" do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      settings = %{"aspect_ratio" => "9:16", "duration" => "99", "hack" => "value"}

      {:ok, updated} =
        Magus.Chat.update_video_generation_settings(
          conversation,
          %{video_generation_settings: settings},
          actor: user
        )

      assert updated.video_generation_settings == %{"aspect_ratio" => "9:16"}
    end

    test "allows nil settings" do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      {:ok, updated} =
        Magus.Chat.update_video_generation_settings(
          conversation,
          %{video_generation_settings: nil},
          actor: user
        )

      assert updated.video_generation_settings == nil
    end
  end
end
