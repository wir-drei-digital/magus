defmodule Magus.Agents.Actions.GenerateVideoTest do
  @moduledoc """
  Tests for GenerateVideo action.
  """
  use Magus.ResourceCase, async: true

  import Mox

  alias Magus.Agents.Actions.GenerateVideo
  alias Magus.Test.Mocks.VideoGenMock
  alias Magus.Test.MockResponses

  setup :verify_on_exit!

  describe "action metadata" do
    test "has correct name" do
      assert GenerateVideo.name() == "generate_video"
    end

    test "has description" do
      assert GenerateVideo.description() =~ "video"
    end

    test "has required schema fields" do
      schema = GenerateVideo.schema()

      # model_key is required
      model_opt = Keyword.get(schema, :model_key)
      assert model_opt[:required] == true
      assert model_opt[:type] == :string

      # messages is required
      messages_opt = Keyword.get(schema, :messages)
      assert messages_opt[:required] == true
      assert messages_opt[:type] == {:list, :map}

      # user_id is required
      user_opt = Keyword.get(schema, :user_id)
      assert user_opt[:required] == true
    end

    test "has optional fields for image-to-video" do
      schema = GenerateVideo.schema()

      input_image = Keyword.get(schema, :input_image)
      assert input_image[:default] == nil

      attachments = Keyword.get(schema, :attachments)
      assert attachments[:default] == []
    end

    test "has optional emit_context field" do
      schema = GenerateVideo.schema()

      emit_context = Keyword.get(schema, :emit_context)
      assert emit_context[:default] == nil
    end
  end

  describe "run/2" do
    test "generates video from text prompt" do
      expect(VideoGenMock, :chat, fn _messages, _opts ->
        MockResponses.generate_video_response("fake-mp4-video-binary-data", use_content: true)
      end)

      user = generate(user())
      {:ok, conversation} = Magus.Chat.create_conversation(%{}, actor: user)

      params = %{
        model_key: "aimlapi:kling-v1",
        messages: ReqLLM.Context.new([ReqLLM.Context.user("A bird flying through clouds")]),
        user_id: user.id,
        conversation_id: conversation.id
        # emit_context: nil means no events are emitted (for unit testing)
      }

      {:ok, result} = GenerateVideo.run(params, %{})

      # Verify result structure
      assert result.message_id != nil
      assert length(result.attachments) == 1
    end

    test "generates video from input image (i2v)" do
      expect(VideoGenMock, :chat, fn _messages, opts ->
        # Verify image_url is passed for i2v models
        assert Keyword.has_key?(opts, :image_url)
        MockResponses.generate_video_response("fake-mp4-video-binary-data", use_content: true)
      end)

      user = generate(user())
      {:ok, conversation} = Magus.Chat.create_conversation(%{}, actor: user)

      # Use a model from the i2v list (google/veo-3.1-i2v)
      params = %{
        model_key: "aimlapi:google/veo-3.1-i2v",
        messages: ReqLLM.Context.new([ReqLLM.Context.user("Animate this image")]),
        user_id: user.id,
        conversation_id: conversation.id,
        input_image: "data:image/png;base64,iVBORw0KGgo="
        # emit_context: nil means no events are emitted (for unit testing)
      }

      {:ok, result} = GenerateVideo.run(params, %{})

      assert length(result.attachments) == 1
    end

    test "returns error when i2v model used without image" do
      # Don't set up a mock - we want to test the real AimlapiClient validation
      # The mock is bypassed by calling AimlapiClient directly
      alias Magus.Agents.Providers.AimlapiClient

      messages = [%{role: "user", content: "Animate this image"}]
      opts = [model: "google/veo-3.1-i2v"]

      # Should return an error since no image is provided for i2v model
      assert {:error, {:missing_image, message}} = AimlapiClient.chat(messages, opts)
      assert message =~ "requires an image input"
    end
  end

  describe "openrouter provider" do
    test "records total_cost from the provider usage.cost" do
      require Ash.Query

      expect(Magus.Test.Mocks.OpenRouterVideoMock, :chat, fn _messages, opts ->
        assert opts[:model] == "google/veo-3.1-fast"

        {:ok,
         %{
           text: "",
           videos: [%{"content" => "FAKE", "mime_type" => "video/mp4"}],
           images: [],
           usage: %{"cost" => 0.25},
           duration: 6
         }}
      end)

      user = generate(user())
      {:ok, conversation} = Magus.Chat.create_conversation(%{}, actor: user)

      params = %{
        model_key: "openrouter:google/veo-3.1-fast",
        model_id: Ash.UUIDv7.generate(),
        model_name: "Veo 3.1 Fast",
        messages: ReqLLM.Context.new([ReqLLM.Context.user("a red bird flying")]),
        user_id: user.id,
        conversation_id: conversation.id,
        video_config: %{"duration" => "6"}
      }

      {:ok, result} = GenerateVideo.run(params, %{})
      assert length(result.attachments) == 1

      [usage] =
        Magus.Usage.MessageUsage
        |> Ash.Query.filter(conversation_id == ^conversation.id)
        |> Ash.read!(authorize?: false)

      assert Decimal.equal?(usage.total_cost, Decimal.from_float(0.25))
    end
  end
end
