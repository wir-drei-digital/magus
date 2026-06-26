defmodule Magus.Agents.Tools.Media.GenerateImageTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Media.GenerateImage

  describe "display_name/0" do
    test "returns user-facing label" do
      assert GenerateImage.display_name() == "Generating image..."
    end
  end

  describe "summarize_output/1" do
    test "summarizes successful generation" do
      assert GenerateImage.summarize_output(%{__attachments__: ["a", "b"]}) ==
               "Generated 2 image(s)"
    end

    test "summarizes error" do
      assert GenerateImage.summarize_output(%{error: "boom"}) == "Error: boom"
    end

    test "summarizes unknown" do
      assert GenerateImage.summarize_output(%{}) == "Completed"
    end
  end

  describe "run/2 - model param" do
    setup do
      user = generate(user())
      {:ok, conversation} = Magus.Chat.create_conversation(%{}, actor: user)

      context = %{
        user_id: user.id,
        conversation_id: conversation.id
      }

      %{user: user, conversation: conversation, context: context}
    end

    test "accepts an explicit image-capable model_key", %{context: context} do
      override =
        generate(
          model(
            key: "openrouter:openai/gpt-5-image",
            output_modalities: ["text", "image"]
          )
        )

      params = %{"prompt" => "a sunset", "model" => override.key}

      # With only the override model seeded (no default), resolve_model_key
      # must be using the param value: otherwise fetch_model_by_key would
      # fail with "Model not found".
      assert {:ok, result} = GenerateImage.run(params, context)
      # Refute only when there IS an error — a truly successful result has no :error key.
      if error = result[:error] do
        refute error =~ "Model not found"
      end
    end

    test "rejects a model that does not generate images", %{context: context} do
      text_only =
        generate(
          model(
            key: "openrouter:openai/gpt-5.2",
            output_modalities: ["text"]
          )
        )

      params = %{"prompt" => "a sunset", "model" => text_only.key}

      assert {:ok, %{error: error}} = GenerateImage.run(params, context)
      assert error =~ "does not generate images"
      assert error =~ text_only.key
    end

    test "returns an error when model_key is unknown", %{context: context} do
      params = %{
        "prompt" => "a sunset",
        "model" => "openrouter:nonexistent/fake-model-zzz"
      }

      assert {:ok, %{error: error}} = GenerateImage.run(params, context)
      assert error =~ "Model not found"
    end
  end
end
