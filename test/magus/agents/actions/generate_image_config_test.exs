defmodule Magus.Agents.Actions.GenerateImageConfigTest do
  @moduledoc """
  Tests for image_config forwarding through GenerateImage action.
  """
  use Magus.ResourceCase, async: true

  import Mox

  alias Magus.Agents.Actions.GenerateImage
  alias Magus.Test.Mocks.ImageGenMock
  alias Magus.Test.MockResponses

  setup :verify_on_exit!

  describe "image_config forwarding" do
    test "passes image_config to the image gen client" do
      image_config = %{"aspect_ratio" => "16:9", "image_size" => "2K"}

      expect(ImageGenMock, :generate_image, fn _model, _context, opts ->
        assert opts[:image_config] == image_config
        MockResponses.generate_image_response("fake-png-data")
      end)

      user = generate(user())
      {:ok, conversation} = Magus.Chat.create_conversation(%{}, actor: user)

      params = %{
        model_key: "openrouter:dall-e-3",
        messages: ReqLLM.Context.new([ReqLLM.Context.user("A sunset")]),
        user_id: user.id,
        conversation_id: conversation.id,
        image_config: image_config
      }

      assert {:ok, _result} = GenerateImage.run(params, %{})
    end

    test "passes nil image_config when not provided" do
      expect(ImageGenMock, :generate_image, fn _model, _context, opts ->
        assert opts[:image_config] == nil
        MockResponses.generate_image_response("fake-png-data")
      end)

      user = generate(user())
      {:ok, conversation} = Magus.Chat.create_conversation(%{}, actor: user)

      params = %{
        model_key: "openrouter:dall-e-3",
        messages: ReqLLM.Context.new([ReqLLM.Context.user("A sunset")]),
        user_id: user.id,
        conversation_id: conversation.id
      }

      assert {:ok, _result} = GenerateImage.run(params, %{})
    end
  end
end
