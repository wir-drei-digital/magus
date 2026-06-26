defmodule Magus.Agents.Providers.FalClientTest do
  use ExUnit.Case, async: false

  alias Magus.Agents.Providers.FalClient

  describe "image_to_video_model?/1" do
    test "returns true for i2v models" do
      assert FalClient.image_to_video_model?("fal-ai/veo3.1/image-to-video")
      assert FalClient.image_to_video_model?("fal-ai/veo3.1/fast/image-to-video")
      assert FalClient.image_to_video_model?("fal-ai/sora-2/image-to-video")
      assert FalClient.image_to_video_model?("fal-ai/bytedance/seedance/v1/lite/image-to-video")
    end

    test "returns false for t2v models" do
      refute FalClient.image_to_video_model?("fal-ai/veo3.1")
      refute FalClient.image_to_video_model?("fal-ai/veo3.1/fast")
      refute FalClient.image_to_video_model?("fal-ai/sora-2/text-to-video")
      refute FalClient.image_to_video_model?("fal-ai/bytedance/seedance/v1/lite/text-to-video")
    end
  end

  describe "build_request_body/2" do
    test "builds Veo 3.1 t2v body with duration as string with 's' suffix" do
      body =
        FalClient.build_request_body("fal-ai/veo3.1", %{
          prompt: "A sunset over mountains",
          duration: 8,
          aspect_ratio: "16:9",
          resolution: "720p",
          generate_audio: true
        })

      assert body["prompt"] == "A sunset over mountains"
      assert body["duration"] == "8s"
      assert body["aspect_ratio"] == "16:9"
      assert body["resolution"] == "720p"
      assert body["generate_audio"] == true
      refute Map.has_key?(body, "image_url")
    end

    test "builds Veo 3.1 i2v body with image_url" do
      body =
        FalClient.build_request_body("fal-ai/veo3.1/image-to-video", %{
          prompt: "Animate this",
          image_url: "https://example.com/img.jpg",
          duration: 4
        })

      assert body["prompt"] == "Animate this"
      assert body["image_url"] == "https://example.com/img.jpg"
      assert body["duration"] == "4s"
    end

    test "builds Sora 2 body with duration as integer" do
      body =
        FalClient.build_request_body("fal-ai/sora-2/text-to-video", %{
          prompt: "A cat playing",
          duration: 8,
          aspect_ratio: "16:9",
          resolution: "720p"
        })

      assert body["prompt"] == "A cat playing"
      assert body["duration"] == 8
      assert body["aspect_ratio"] == "16:9"
      assert body["resolution"] == "720p"
      refute Map.has_key?(body, "generate_audio")
    end

    test "builds Seedance body with duration as plain string" do
      body =
        FalClient.build_request_body("fal-ai/bytedance/seedance/v1/lite/text-to-video", %{
          prompt: "A dance scene",
          duration: 5,
          aspect_ratio: "16:9",
          resolution: "720p"
        })

      assert body["prompt"] == "A dance scene"
      assert body["duration"] == "5"
      assert body["aspect_ratio"] == "16:9"
      assert body["resolution"] == "720p"
    end

    test "omits nil values" do
      body =
        FalClient.build_request_body("fal-ai/veo3.1", %{
          prompt: "Test",
          duration: nil,
          aspect_ratio: nil
        })

      assert body["prompt"] == "Test"
      refute Map.has_key?(body, "duration")
      refute Map.has_key?(body, "aspect_ratio")
    end
  end

  describe "chat/2" do
    test "returns error when FAL_KEY is not set" do
      original = System.get_env("FAL_KEY")
      System.delete_env("FAL_KEY")
      on_exit(fn -> if original, do: System.put_env("FAL_KEY", original) end)

      messages = [%{role: "user", content: "Generate a video of a sunset"}]
      opts = [model: "fal-ai/veo3.1"]

      assert {:error, :missing_api_key} = FalClient.chat(messages, opts)
    end

    test "returns error when i2v model used without image" do
      messages = [%{role: "user", content: "Animate this"}]
      opts = [model: "fal-ai/veo3.1/image-to-video"]

      assert {:error, {:missing_image, msg}} = FalClient.chat(messages, opts)
      assert msg =~ "requires an image"
    end
  end
end
