defmodule Magus.Models.RolesWiringTest do
  use Magus.DataCase, async: false

  alias Magus.Agents.Routing.ModelKeyResolver

  test "router image fallback uses the image_default role (not stale dall-e-3)" do
    assert ModelKeyResolver.default_model_key(:image) ==
             "openrouter:google/gemini-3.1-flash-image-preview"
  end

  test "router video fallback uses the video_t2v role" do
    assert ModelKeyResolver.default_model_key(:video) == "openrouter:google/veo-3.1-fast"
  end

  test "chat_default role assignment drives default_model_key(:chat)" do
    model =
      Magus.Chat.Model
      |> Ash.Changeset.for_create(:create, %{
        name: "Assigned Chat Default",
        key: "openrouter:assigned/chat",
        provider: "Test",
        context_window: 1_000
      })
      |> Ash.create!(authorize?: false)

    {:ok, _} =
      Magus.Models.assign_role(%{role: "chat_default", model_id: model.id},
        authorize?: false
      )

    assert ModelKeyResolver.default_model_key(:chat) == "openrouter:assigned/chat"
  end

  test "router fallbacks prefer the image_default role assignment" do
    model =
      Magus.Chat.Model
      |> Ash.Changeset.for_create(:create, %{
        name: "Assigned Image Default",
        key: "openrouter:assigned/image",
        provider: "Test",
        context_window: 1_000,
        output_modalities: ["image"]
      })
      |> Ash.create!(authorize?: false)

    {:ok, _} =
      Magus.Models.assign_role(%{role: "image_default", model_id: model.id},
        authorize?: false
      )

    assert ModelKeyResolver.default_model_key(:image) == "openrouter:assigned/image"
  end
end
