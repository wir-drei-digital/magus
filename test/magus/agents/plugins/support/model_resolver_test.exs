defmodule Magus.Agents.Plugins.Support.ModelResolverTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Agents.Plugins.Support.ModelResolver

  describe "resolve_model/3 with :auto keys" do
    test "resolves :auto image to image generation model via routing slot" do
      image_model = generate(model(output_modalities: ["image"]))
      routing_slot(model_id: image_model.id, specialty: :image, tier: :standard)

      model_keys = %{chat: "some-chat-model", image: :auto, video: "some-video"}
      result = ModelResolver.resolve_model(model_keys, :image_generation, nil)

      assert result.key == image_model.key
    end

    test "resolves :auto image to the image_default role assignment when no routing slot" do
      image_model = generate(model(output_modalities: ["image"]))

      {:ok, _} =
        Magus.Models.assign_role(%{role: "image_default", model_id: image_model.id},
          authorize?: false
        )

      model_keys = %{chat: "some-chat-model", image: :auto, video: "some-video"}
      result = ModelResolver.resolve_model(model_keys, :image_generation, nil)

      assert result.key == image_model.key
    end

    test "resolves :auto video to text_to_video routing slot" do
      video_model = generate(model(output_modalities: ["video"]))
      routing_slot(model_id: video_model.id, specialty: :text_to_video, tier: :standard)

      model_keys = %{chat: "some-chat-model", image: "some-image", video: :auto}
      result = ModelResolver.resolve_model(model_keys, :video_generation, nil)

      assert result.key == video_model.key
    end

    test "falls back to a valid model when :auto for chat mode" do
      model_keys = %{chat: :auto, image: "img", video: "vid"}
      result = ModelResolver.resolve_model(model_keys, :chat, nil)

      # Should return a model struct (either from DB default or hardcoded fallback)
      assert %Magus.Chat.Model{} = result
      assert is_binary(result.key) or is_nil(result.key)
    end
  end
end
