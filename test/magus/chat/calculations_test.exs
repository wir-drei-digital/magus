defmodule Magus.Chat.CalculationsTest do
  @moduledoc """
  Tests for Ash calculations in the Chat domain.
  """
  use Magus.ResourceCase, async: true

  alias Magus.Chat

  describe "Conversation.needs_title" do
    test "returns true when no title and has messages" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      # Add more than 3 messages
      for i <- 1..4 do
        {:ok, _} =
          Chat.send_user_message(
            %{text: "Message #{i}", conversation_id: conversation.id},
            actor: user
          )
      end

      {:ok, loaded} = Ash.load(conversation, :needs_title, actor: user)

      assert loaded.needs_title == true
    end

    test "returns false when title is set" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{title: "Has a Title"}, actor: user)

      {:ok, loaded} = Ash.load(conversation, :needs_title, actor: user)

      assert loaded.needs_title == false
    end
  end

  describe "Conversation.member_count" do
    test "counts accepted members" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      member1 = generate(user())
      member2 = generate(user())

      # add_member policy uses relationship filters that can't evaluate on create
      {:ok, m1} =
        Chat.add_conversation_member(conversation.id, member1.id, %{}, authorize?: false)

      {:ok, _m2} =
        Chat.add_conversation_member(conversation.id, member2.id, %{}, authorize?: false)

      # Accept only one
      {:ok, _} = Chat.accept_conversation_invitation(m1, actor: member1)

      {:ok, loaded} = Ash.load(conversation, :member_count, actor: owner)

      # Owner (auto-accepted) + member1 (accepted) = 2
      assert loaded.member_count == 2
    end
  end

  describe "Message.needs_response" do
    test "returns true for user message without response" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(
          %{text: "Hello", conversation_id: conversation.id},
          actor: user
        )

      {:ok, loaded} = Ash.load(message, :needs_response, actor: user)

      assert loaded.needs_response == true
    end
  end

  describe "MessageUsage.total_cost" do
    test "stores total cost" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(
          %{text: "Hello", conversation_id: conversation.id},
          actor: user
        )

      model = generate(model())

      # MessageUsage has no authorizer - analytics/billing resource
      # total_cost is now a stored attribute, not a calculation
      {:ok, usage} =
        Magus.Usage.create_message_usage(
          %{
            user_id: user.id,
            message_id: message.id,
            conversation_id: conversation.id,
            model_id: model.id,
            model_name: "test-model",
            prompt_tokens: 100,
            completion_tokens: 50,
            total_tokens: 150,
            input_cost: Decimal.new("0.0010"),
            output_cost: Decimal.new("0.0020"),
            total_cost: Decimal.new("0.0030")
          },
          authorize?: false
        )

      assert Decimal.eq?(usage.total_cost, Decimal.new("0.003"))
    end

    test "UsageRecorder calculates total_cost from input and output costs" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(
          %{text: "Hello", conversation_id: conversation.id},
          actor: user
        )

      # Create model with known pricing: $1/M input, $2/M output
      model =
        generate(
          model(
            input_cost_value: Decimal.new("1"),
            input_cost_unit: :per_million_tokens,
            output_cost_value: Decimal.new("2"),
            output_cost_unit: :per_million_tokens
          )
        )

      # UsageRecorder calculates costs before calling the action
      {:ok, usage} =
        Magus.Agents.Persistence.UsageRecorder.record(
          user_id: user.id,
          message_id: message.id,
          conversation_id: conversation.id,
          model: model,
          usage: %{"prompt_tokens" => 1_000_000, "completion_tokens" => 1_000_000}
        )

      # 1M tokens * $1/M = $1 input, 1M tokens * $2/M = $2 output = $3 total
      assert Decimal.eq?(usage.total_cost, Decimal.new("3"))
    end
  end

  describe "ConversationInviteLink.is_valid" do
    test "returns true for active non-expired link" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: user)

      # create_invite_link policy uses relationship filters that can't evaluate on create
      {:ok, link} = Chat.create_invite_link(conversation.id, %{}, actor: user, authorize?: false)

      {:ok, loaded} =
        Ash.load(link, [:is_valid, :is_expired, :is_exhausted], actor: user)

      assert loaded.is_valid == true
      assert loaded.is_expired == false
      assert loaded.is_exhausted == false
    end

    test "returns false when deactivated" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: user)

      # create_invite_link policy uses relationship filters that can't evaluate on create
      {:ok, link} = Chat.create_invite_link(conversation.id, %{}, actor: user, authorize?: false)
      {:ok, deactivated} = Chat.deactivate_invite_link(link, actor: user)

      {:ok, loaded} = Ash.load(deactivated, :is_valid, actor: user)

      assert loaded.is_valid == false
    end
  end

  describe "Message.as_llm_message" do
    # Minimal valid PNG file (1x1 transparent pixel)
    @png_content <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49,
                   0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06,
                   0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44,
                   0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D,
                   0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42,
                   0x60, 0x82>>

    test "converts user message to LLM format" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(
          %{text: "Hello AI", conversation_id: conversation.id},
          actor: user
        )

      {:ok, loaded} = Ash.load(message, :as_llm_message, authorize?: false)

      assert loaded.as_llm_message.role == :user
      # Content is a list of ContentParts
      [first_part | _] = loaded.as_llm_message.content
      assert first_part.text == "Hello AI"
    end

    test "converts user message with file attachments using proper authorization" do
      # This test ensures the actor is correctly passed through to load_llm_content_parts!
      # which requires actor_present() policy. Without proper actor propagation, this
      # would fail with Ash.Error.Forbidden.
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      # Create a file attachment
      {:ok, file} =
        Magus.Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "test.png", user_id: user.id, conversation_id: conversation.id},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      # Create message then set attachments (attachments not in :create accept list)
      {:ok, message} =
        Chat.create_message(%{text: "Check this image", conversation_id: conversation.id},
          actor: user
        )

      # Update message with attachment using direct changeset
      {:ok, message} =
        message
        |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
        |> Ash.Changeset.force_change_attribute(:attachments, [file.id])
        |> Ash.update(authorize?: false)

      # Load with authorization enabled - this will fail if actor isn't passed to
      # load_llm_content_parts! in the AsLlmMessage calculation
      {:ok, loaded} = Ash.load(message, :as_llm_message, actor: user)

      assert loaded.as_llm_message.role == :user
      # Content should be a list of parts:
      # 1. The user's text
      # 2. A `[file_id: <uuid>]` marker so the LLM can reference it
      # 3. The image content itself
      assert is_list(loaded.as_llm_message.content)
      assert length(loaded.as_llm_message.content) >= 3

      [text_part, id_marker, image_part | _] = loaded.as_llm_message.content

      assert text_part.type == :text
      assert text_part.text == "Check this image"

      assert id_marker.type == :text
      assert id_marker.text == "[file_id: #{file.id}]"

      assert image_part.type == :image
    end

    test "converts assistant tool-call message with tool_call_data.tool_calls" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      response_id = Ash.UUIDv7.generate()

      {:ok, message} =
        Magus.Chat.Message
        |> Ash.Changeset.for_create(:upsert_response, %{
          id: response_id,
          text: "I'll use a tool.",
          conversation_id: conversation.id,
          complete: true,
          tool_call_data: %{
            tool_calls: [
              %{
                id: "tool_call_1",
                name: "roll_dice",
                arguments: %{"notation" => "2d10"}
              }
            ]
          }
        })
        |> Ash.create(actor: %Magus.Agents.Support.AiAgent{})

      # Default: include_tool_calls is false, so tool_calls are not populated
      {:ok, loaded} = Ash.load(message, :as_llm_message, authorize?: false)
      assert loaded.as_llm_message.role == :assistant
      assert loaded.as_llm_message.tool_calls in [nil, []]

      # With include_tool_calls: true, tool_calls are included
      {:ok, loaded_with_tools} =
        Ash.load(message, [as_llm_message: [include_tool_calls: true]], authorize?: false)

      assert loaded_with_tools.as_llm_message.role == :assistant
      assert is_list(loaded_with_tools.as_llm_message.tool_calls)

      assert Enum.any?(
               loaded_with_tools.as_llm_message.tool_calls,
               &(ReqLLM.ToolCall.name(&1) == "roll_dice")
             )
    end

    test "converts tool event message to tool result LLM message" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      event_id = Ash.UUIDv7.generate()

      event =
        Chat.upsert_event_message!(
          event_id,
          "roll_dice completed",
          conversation.id,
          %{
            id: event_id,
            tool_use_id: "tool_call_1",
            tool_name: "roll_dice",
            output: %{result: 11},
            status: :success
          },
          true,
          authorize?: false
        )

      {:ok, loaded} = Ash.load(event, :as_llm_message, authorize?: false)

      assert loaded.as_llm_message.role == :tool
      assert loaded.as_llm_message.tool_call_id == "tool_call_1"
      assert loaded.as_llm_message.name == "roll_dice"
      assert is_list(loaded.as_llm_message.content)
      content_text = Enum.map_join(loaded.as_llm_message.content, "", &Map.get(&1, :text, ""))
      assert String.contains?(content_text, "11")
    end
  end
end
