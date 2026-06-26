defmodule Magus.Agents.Actions.GenerateImageTest do
  @moduledoc """
  Tests for GenerateImage action.
  """
  use Magus.ResourceCase, async: true

  import Mox

  alias Magus.Agents.Actions.GenerateImage
  alias Magus.Test.Mocks.ImageGenMock
  alias Magus.Test.MockResponses

  setup :verify_on_exit!

  describe "action metadata" do
    test "has correct name" do
      assert GenerateImage.name() == "generate_image"
    end

    test "has description" do
      assert GenerateImage.description() =~ "image"
    end

    test "has required schema fields" do
      schema = GenerateImage.schema()

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

    test "has optional emit_context field" do
      schema = GenerateImage.schema()

      emit_context = Keyword.get(schema, :emit_context)
      assert emit_context[:default] == nil
    end
  end

  describe "run/2" do
    test "generates image and creates resource" do
      expect(ImageGenMock, :generate_image, fn _model, _context, _opts ->
        MockResponses.generate_image_response("fake-png-image-binary-data")
      end)

      user = generate(user())
      {:ok, conversation} = Magus.Chat.create_conversation(%{}, actor: user)

      params = %{
        model_key: "openrouter:dall-e-3",
        messages: ReqLLM.Context.new([ReqLLM.Context.user("A sunset over mountains")]),
        user_id: user.id,
        conversation_id: conversation.id
        # emit_context: nil means no events are emitted (for unit testing)
      }

      {:ok, result} = GenerateImage.run(params, %{})

      # Verify result structure
      assert result.message_id != nil
      assert length(result.attachments) == 1
      assert is_map(result.usage)
    end

    test "handles multiple images in response" do
      expect(ImageGenMock, :generate_image, fn _model, _context, _opts ->
        MockResponses.generate_multi_image_response([
          "fake-png-image-1",
          "fake-png-image-2"
        ])
      end)

      user = generate(user())
      {:ok, conversation} = Magus.Chat.create_conversation(%{}, actor: user)

      params = %{
        model_key: "openrouter:dall-e-3",
        messages: ReqLLM.Context.new([ReqLLM.Context.user("Two images please")]),
        user_id: user.id,
        conversation_id: conversation.id
        # emit_context: nil means no events are emitted (for unit testing)
      }

      {:ok, result} = GenerateImage.run(params, %{})

      assert length(result.attachments) == 2
    end
  end

  describe "usage cost recording" do
    test "records MessageUsage.total_cost from the provider usage.cost" do
      require Ash.Query

      expect(Magus.Test.Mocks.ImageGenMock, :generate_image, fn _model, _context, _opts ->
        {:ok,
         %{
           text: "",
           images: [
             %{"type" => "image", "data_url" => "data:image/png;base64,#{Base.encode64("img")}"}
           ],
           usage: %{"prompt_tokens" => 12, "completion_tokens" => 0, "cost" => 0.136}
         }}
      end)

      user = generate(user())
      {:ok, conversation} = Magus.Chat.create_conversation(%{}, actor: user)

      params = %{
        model_key: "openrouter:google/gemini-3.1-flash-image-preview",
        model_id: Ash.UUIDv7.generate(),
        model_name: "Gemini 3.1 Flash Image",
        messages: ReqLLM.Context.new([ReqLLM.Context.user("a red bird")]),
        user_id: user.id,
        conversation_id: conversation.id
      }

      {:ok, _result} = Magus.Agents.Actions.GenerateImage.run(params, %{})

      [usage] =
        Magus.Usage.MessageUsage
        |> Ash.Query.filter(conversation_id == ^conversation.id)
        |> Ash.read!(authorize?: false)

      assert Decimal.equal?(usage.total_cost, Decimal.from_float(0.136))
      assert Decimal.equal?(usage.provider_cost, Decimal.from_float(0.136))
    end
  end
end
