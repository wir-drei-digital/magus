defmodule Magus.Agents.Routing.ModelKeyResolverTest do
  @moduledoc """
  Unit tests for the ModelKeyResolver module.

  Tests the model key resolution priority:
  1. Conversation-specific model selection
  2. User's default model preference
  3. System default model
  """
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Routing.ModelKeyResolver

  describe "resolve/1" do
    test "uses conversation model when available" do
      conv_model = generate(model(key: "conv/model"))
      _user = generate(user())

      # Simulate conversation with model selected
      conversation = %{
        selected_model: conv_model,
        selected_image_model: nil,
        selected_video_model: nil,
        custom_agent: nil,
        user: %{
          selected_model: nil,
          selected_image_model: nil,
          selected_video_model: nil
        }
      }

      {:ok, model_keys} = ModelKeyResolver.resolve(conversation)

      assert model_keys.chat == "conv/model"
    end

    test "falls back to user model when conversation model is nil" do
      user_model = generate(model(key: "user/model"))

      conversation = %{
        selected_model: nil,
        selected_image_model: nil,
        selected_video_model: nil,
        custom_agent: nil,
        user: %{
          selected_model: user_model,
          selected_image_model: nil,
          selected_video_model: nil
        }
      }

      {:ok, model_keys} = ModelKeyResolver.resolve(conversation)

      assert model_keys.chat == "user/model"
    end

    test "falls back to system default when both are nil" do
      conversation = %{
        selected_model: nil,
        selected_image_model: nil,
        selected_video_model: nil,
        custom_agent: nil,
        user: %{
          selected_model: nil,
          selected_image_model: nil,
          selected_video_model: nil
        }
      }

      {:ok, model_keys} = ModelKeyResolver.resolve(conversation)

      # Should return :auto when no explicit model selection exists
      assert model_keys.chat == :auto
    end

    test "resolves all model types independently" do
      chat_model = generate(model(key: "chat/model"))
      image_model = generate(model(key: "image/model"))
      video_model = generate(model(key: "video/model"))

      conversation = %{
        selected_model: chat_model,
        selected_image_model: image_model,
        selected_video_model: video_model,
        custom_agent: nil,
        user: %{
          selected_model: nil,
          selected_image_model: nil,
          selected_video_model: nil
        }
      }

      {:ok, model_keys} = ModelKeyResolver.resolve(conversation)

      assert model_keys.chat == "chat/model"
      assert model_keys.image == "image/model"
      assert model_keys.video == "video/model"
    end

    test "mixes sources for different model types" do
      conv_chat = generate(model(key: "conv/chat"))
      user_image = generate(model(key: "user/image"))

      conversation = %{
        selected_model: conv_chat,
        selected_image_model: nil,
        selected_video_model: nil,
        custom_agent: nil,
        user: %{
          selected_model: nil,
          selected_image_model: user_image,
          selected_video_model: nil
        }
      }

      {:ok, model_keys} = ModelKeyResolver.resolve(conversation)

      assert model_keys.chat == "conv/chat"
      assert model_keys.image == "user/image"
      # Video falls back to :auto
      assert model_keys.video == :auto
    end

    test "returns :auto for all model types when no explicit selection exists" do
      conversation = %{
        selected_model: nil,
        selected_image_model: nil,
        selected_video_model: nil,
        custom_agent: nil,
        user: %{
          selected_model: nil,
          selected_image_model: nil,
          selected_video_model: nil
        }
      }

      {:ok, model_keys} = ModelKeyResolver.resolve(conversation)

      assert model_keys.chat == :auto
      assert model_keys.image == :auto
      assert model_keys.video == :auto
    end
  end

  describe "default_model_key/1" do
    test "default video fallback is the OpenRouter Veo 3.1 Fast key" do
      # With no video_t2v role assignment in the test DB, the code default applies.
      assert ModelKeyResolver.default_model_key(:video) == "openrouter:google/veo-3.1-fast"
    end
  end
end
