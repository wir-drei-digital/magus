defmodule Magus.Agents.Actions.ClassifyVideoIntentTest do
  use Magus.DataCase, async: true

  alias Magus.Agents.Actions.ClassifyVideoIntent

  describe "run/2" do
    test "classifies plain text as text_to_video" do
      {:ok, result} =
        ClassifyVideoIntent.run(
          %{text: "Create a video of a sunset over the ocean", conversation_context: []},
          %{}
        )

      assert result.intent == :text_to_video
      assert result.source_image_url == nil
    end

    test "classifies message with image attachment as image_to_video via heuristic" do
      context = [
        %{
          role: :user,
          text: "Animate this image",
          attachments: [%{"url" => "https://example.com/photo.jpg", "type" => "image"}]
        }
      ]

      {:ok, result} =
        ClassifyVideoIntent.run(
          %{text: "Animate this image", conversation_context: context},
          %{}
        )

      assert result.intent == :image_to_video
      assert result.source_image_url == "https://example.com/photo.jpg"
      assert result.method == :heuristic
    end

    test "defaults to text_to_video when no LLM configured" do
      {:ok, result} =
        ClassifyVideoIntent.run(
          %{text: "Make a video of a dancing robot", conversation_context: []},
          %{}
        )

      assert result.intent == :text_to_video
      assert result.source_image_url == nil
    end

    test "handles nil text" do
      {:ok, result} =
        ClassifyVideoIntent.run(
          %{text: nil, conversation_context: []},
          %{}
        )

      assert result.intent == :text_to_video
    end

    test "detects 'make this move' as image_to_video heuristic" do
      context = [
        %{
          role: :user,
          text: "Make this move",
          attachments: [%{"url" => "https://example.com/cat.png", "type" => "image/png"}]
        }
      ]

      {:ok, result} =
        ClassifyVideoIntent.run(
          %{text: "Make this move", conversation_context: context},
          %{}
        )

      assert result.intent == :image_to_video
      assert result.source_image_url == "https://example.com/cat.png"
      assert result.method == :heuristic
    end

    test "detects 'turn this into a video' as image_to_video heuristic" do
      context = [
        %{
          role: :user,
          text: "Turn this into a video",
          attachments: [%{"url" => "https://example.com/scene.jpg", "type" => "image"}]
        }
      ]

      {:ok, result} =
        ClassifyVideoIntent.run(
          %{text: "Turn this into a video", conversation_context: context},
          %{}
        )

      assert result.intent == :image_to_video
      assert result.source_image_url == "https://example.com/scene.jpg"
    end

    test "does not trigger heuristic without image attachment" do
      context = [
        %{role: :user, text: "Animate this image", attachments: []}
      ]

      {:ok, result} =
        ClassifyVideoIntent.run(
          %{text: "Animate this image", conversation_context: context},
          %{}
        )

      # No image attachment, so falls through to LLM path (which defaults to text_to_video in test)
      assert result.intent == :text_to_video
    end

    test "does not trigger heuristic without animation keywords" do
      context = [
        %{
          role: :user,
          text: "What is in this image?",
          attachments: [%{"url" => "https://example.com/photo.jpg", "type" => "image"}]
        }
      ]

      {:ok, result} =
        ClassifyVideoIntent.run(
          %{text: "What is in this image?", conversation_context: context},
          %{}
        )

      # Has image but no animation keyword, so falls through to LLM path
      assert result.intent == :text_to_video
    end

    test "finds the latest image from multiple attachments" do
      context = [
        %{
          role: :user,
          text: "Earlier image",
          attachments: [%{"url" => "https://example.com/old.jpg", "type" => "image"}]
        },
        %{
          role: :user,
          text: "Animate this",
          attachments: [%{"url" => "https://example.com/new.jpg", "type" => "image"}]
        }
      ]

      {:ok, result} =
        ClassifyVideoIntent.run(
          %{text: "Animate this", conversation_context: context},
          %{}
        )

      assert result.intent == :image_to_video
      assert result.source_image_url == "https://example.com/new.jpg"
    end
  end
end

defmodule Magus.Agents.Actions.ClassifyVideoIntentLLMTest do
  use Magus.DataCase, async: false

  import Mox

  alias Magus.Agents.Actions.ClassifyVideoIntent
  alias Magus.Test.MockResponses

  setup :verify_on_exit!

  setup do
    original = Application.get_env(:magus, :agents, [])
    agents_config = Keyword.put(original, :classification_model, "openrouter:test/model")
    Application.put_env(:magus, :agents, agents_config)

    on_exit(fn ->
      Application.put_env(:magus, :agents, original)
    end)

    :ok
  end

  defp mock_video_classification(intent, confidence, source_image_url \\ nil) do
    expect(Magus.Test.Mocks.LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
      MockResponses.generate_object_response(%{
        "intent" => to_string(intent),
        "confidence" => confidence,
        "source_image_url" => source_image_url
      })
    end)
  end

  describe "LLM video intent classification" do
    test "classifies text_to_video via LLM" do
      mock_video_classification(:text_to_video, 0.92)

      {:ok, result} =
        ClassifyVideoIntent.run(
          %{text: "Create a cinematic video of a city at night", conversation_context: []},
          %{}
        )

      assert result.intent == :text_to_video
      assert result.source_image_url == nil
      assert result.method == :llm
      assert_in_delta result.confidence, 0.92, 0.01
    end

    test "classifies image_to_video via LLM" do
      mock_video_classification(
        :image_to_video,
        0.88,
        "https://example.com/photo.jpg"
      )

      context = [
        %{
          role: :agent,
          text: "Here is the image you requested",
          attachments: [%{"url" => "https://example.com/photo.jpg", "type" => "image"}]
        }
      ]

      # Text does NOT match the simple animation regex, so LLM path is taken
      {:ok, result} =
        ClassifyVideoIntent.run(
          %{
            text: "Use that photo as the basis for a cinematic sequence",
            conversation_context: context
          },
          %{}
        )

      assert result.intent == :image_to_video
      assert result.source_image_url == "https://example.com/photo.jpg"
      assert result.method == :llm
    end
  end

  describe "LLM error handling" do
    test "falls back to text_to_video on LLM error" do
      expect(Magus.Test.Mocks.LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        {:error, %{error: "service unavailable"}}
      end)

      {:ok, result} =
        ClassifyVideoIntent.run(
          %{text: "Create a video of waves", conversation_context: []},
          %{}
        )

      assert result.intent == :text_to_video
      assert result.method == :heuristic
      assert result.confidence == 0.0
    end

    test "falls back to text_to_video when LLM returns non-map object" do
      expect(Magus.Test.Mocks.LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        {:ok, %{object: nil, usage: %{input_tokens: 5, output_tokens: 5}}}
      end)

      {:ok, result} =
        ClassifyVideoIntent.run(
          %{text: "Generate video", conversation_context: []},
          %{}
        )

      assert result.intent == :text_to_video
      assert result.method == :heuristic
    end

    test "clamps confidence to 0-1 range" do
      expect(Magus.Test.Mocks.LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        MockResponses.generate_object_response(%{
          "intent" => "text_to_video",
          "confidence" => 1.5
        })
      end)

      {:ok, result} =
        ClassifyVideoIntent.run(
          %{text: "Make a video", conversation_context: []},
          %{}
        )

      assert result.confidence == 1.0
    end
  end

  describe "LLM call contract" do
    test "passes correct model, schema, and system prompt" do
      expect(Magus.Test.Mocks.LLMMock, :generate_object, fn model, prompt, schema, opts ->
        assert model == "openrouter:test/model"
        assert is_binary(prompt)

        assert schema["properties"]["intent"]["enum"] == [
                 "text_to_video",
                 "image_to_video"
               ]

        assert schema["properties"]["source_image_url"]
        assert Keyword.has_key?(opts, :system_prompt)

        MockResponses.generate_object_response(%{
          "intent" => "text_to_video",
          "confidence" => 0.7
        })
      end)

      ClassifyVideoIntent.run(
        %{text: "Create a video of mountains", conversation_context: []},
        %{}
      )
    end

    test "includes conversation context in prompt" do
      context = [
        %{
          role: :agent,
          text: "Here is your image",
          attachments: [%{"url" => "https://example.com/img.jpg", "type" => "image"}]
        }
      ]

      expect(Magus.Test.Mocks.LLMMock, :generate_object, fn _model, prompt, _schema, _opts ->
        assert prompt =~ "Recent conversation"
        assert prompt =~ "Here is your image"
        assert prompt =~ "image: https://example.com/img.jpg"

        MockResponses.generate_object_response(%{
          "intent" => "text_to_video",
          "confidence" => 0.8
        })
      end)

      # Text does NOT match the simple animation regex, so LLM path is taken
      ClassifyVideoIntent.run(
        %{
          text: "Generate a cinematic version of that scene",
          conversation_context: context
        },
        %{}
      )
    end
  end

  describe "heuristic fast path bypasses LLM" do
    test "direct image attachment with animation request bypasses LLM" do
      # No mock expectation -- LLM should not be called
      context = [
        %{
          role: :user,
          text: "Animate this image",
          attachments: [%{"url" => "https://example.com/photo.jpg", "type" => "image"}]
        }
      ]

      {:ok, result} =
        ClassifyVideoIntent.run(
          %{text: "Animate this image", conversation_context: context},
          %{}
        )

      assert result.intent == :image_to_video
      assert result.method == :heuristic
    end
  end
end
