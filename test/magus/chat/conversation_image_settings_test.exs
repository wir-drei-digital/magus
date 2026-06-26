defmodule Magus.Chat.ConversationImageSettingsTest do
  use Magus.ResourceCase, async: true

  describe "update_image_generation_settings" do
    test "persists valid settings on conversation" do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      settings = %{"aspect_ratio" => "16:9", "image_size" => "2K"}

      {:ok, updated} =
        Magus.Chat.update_image_generation_settings(
          conversation,
          %{image_generation_settings: settings},
          actor: user
        )

      assert updated.image_generation_settings == settings
    end

    test "sanitizes invalid values" do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      settings = %{"aspect_ratio" => "99:1", "image_size" => "8K", "extra" => "bad"}

      {:ok, updated} =
        Magus.Chat.update_image_generation_settings(
          conversation,
          %{image_generation_settings: settings},
          actor: user
        )

      assert updated.image_generation_settings == %{}
    end

    test "keeps valid values and drops invalid ones" do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      settings = %{"aspect_ratio" => "1:1", "image_size" => "invalid", "hack" => "value"}

      {:ok, updated} =
        Magus.Chat.update_image_generation_settings(
          conversation,
          %{image_generation_settings: settings},
          actor: user
        )

      assert updated.image_generation_settings == %{"aspect_ratio" => "1:1"}
    end

    test "allows nil settings" do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      {:ok, updated} =
        Magus.Chat.update_image_generation_settings(
          conversation,
          %{image_generation_settings: nil},
          actor: user
        )

      assert updated.image_generation_settings == nil
    end
  end
end
