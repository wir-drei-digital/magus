defmodule Magus.Chat.MessageUsageTest do
  @moduledoc """
  Tests for MessageUsage resource.

  Tests token usage tracking for billing and analytics including:
  - Creating usage records
  - Recording usage from LLM responses
  - Cost calculations
  """
  use Magus.ResourceCase, async: true

  alias Magus.Chat

  describe "create/1" do
    test "creates usage record with token counts" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      model = generate(model())

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
            total_tokens: 150
          },
          authorize?: false
        )

      assert usage.prompt_tokens == 100
      assert usage.completion_tokens == 50
      assert usage.total_tokens == 150
      assert usage.usage_type == :response
    end

    test "creates usage record with different usage types" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      model = generate(model())

      for usage_type <- [:response, :tool_call, :search, :image_generation, :video_generation] do
        {:ok, usage} =
          Magus.Usage.create_message_usage(
            %{
              user_id: user.id,
              message_id: message.id,
              conversation_id: conversation.id,
              model_id: model.id,
              model_name: "test-model",
              usage_type: usage_type,
              prompt_tokens: 10,
              completion_tokens: 5,
              total_tokens: 15
            },
            authorize?: false
          )

        assert usage.usage_type == usage_type
      end
    end

    test "creates usage record with cached tokens" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      model = generate(model())

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
            cached_tokens: 80
          },
          authorize?: false
        )

      assert usage.cached_tokens == 80
    end

    test "creates usage record with reasoning tokens" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      model = generate(model())

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
            reasoning_tokens: 30
          },
          authorize?: false
        )

      assert usage.reasoning_tokens == 30
    end
  end

  describe "record_from_response/1" do
    test "records usage from LLM response map" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      model = generate(model())

      usage_map = %{
        "prompt_tokens" => 100,
        "completion_tokens" => 50,
        "total_tokens" => 150
      }

      {:ok, usage} =
        Magus.Usage.record_message_usage(
          %{
            user_id: user.id,
            message_id: message.id,
            conversation_id: conversation.id,
            model_id: model.id,
            model_name: "test-model",
            usage: usage_map
          },
          authorize?: false
        )

      assert usage.prompt_tokens == 100
      assert usage.completion_tokens == 50
      assert usage.total_tokens == 150
    end

    test "records usage from ReqLLM format (atom keys)" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      model = generate(model())

      # ReqLLM returns usage with atom keys in this format
      usage_map = %{
        input_tokens: 100,
        output_tokens: 50,
        total_tokens: 150,
        input: 100,
        output: 50,
        reasoning: 10,
        cached_input: 25,
        cache_creation: 5,
        total_cost: 0.002
      }

      {:ok, usage} =
        Magus.Usage.record_message_usage(
          %{
            user_id: user.id,
            message_id: message.id,
            conversation_id: conversation.id,
            model_id: model.id,
            model_name: "test-model",
            usage: usage_map
          },
          authorize?: false
        )

      assert usage.prompt_tokens == 100
      assert usage.completion_tokens == 50
      assert usage.total_tokens == 150
      assert usage.reasoning_tokens == 10
      assert usage.cached_tokens == 25
      assert usage.cache_write_tokens == 5
    end

    test "handles empty usage map" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      model = generate(model())

      {:ok, usage} =
        Magus.Usage.record_message_usage(
          %{
            user_id: user.id,
            message_id: message.id,
            conversation_id: conversation.id,
            model_id: model.id,
            model_name: "test-model",
            usage: %{}
          },
          authorize?: false
        )

      assert usage.prompt_tokens == 0
      assert usage.completion_tokens == 0
      assert usage.total_tokens == 0
    end

    test "records with specific usage type" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      model = generate(model())

      {:ok, usage} =
        Magus.Usage.record_message_usage(
          %{
            user_id: user.id,
            message_id: message.id,
            conversation_id: conversation.id,
            model_id: model.id,
            model_name: "test-model",
            usage: %{},
            usage_type: :image_generation
          },
          authorize?: false
        )

      assert usage.usage_type == :image_generation
    end
  end

  describe "record_from_response with new fields" do
    test "records usage with finish_reason" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      model = generate(model())

      {:ok, usage} =
        Magus.Usage.record_message_usage(
          %{
            user_id: user.id,
            message_id: message.id,
            conversation_id: conversation.id,
            model_id: model.id,
            model_name: "test-model",
            usage: %{"prompt_tokens" => 100, "completion_tokens" => 50},
            finish_reason: "stop"
          },
          authorize?: false
        )

      assert usage.finish_reason == "stop"
    end

    test "persists provider_generation_id (survives the ExtractTokens change)" do
      user = generate(user())
      model = generate(model())

      {:ok, usage} =
        Magus.Usage.record_message_usage(
          %{
            user_id: user.id,
            model_id: model.id,
            model_name: "test-model",
            usage: %{},
            provider_generation_id: "gen-abc123"
          },
          authorize?: false
        )

      assert usage.provider_generation_id == "gen-abc123"
      assert usage.total_tokens == 0
      assert is_nil(usage.reconciled_at)
      assert usage.reconciliation_status == :not_required
    end

    test "records usage with tool_calls finish_reason" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      model = generate(model())

      {:ok, usage} =
        Magus.Usage.record_message_usage(
          %{
            user_id: user.id,
            message_id: message.id,
            conversation_id: conversation.id,
            model_id: model.id,
            model_name: "test-model",
            usage: %{},
            finish_reason: "tool_calls"
          },
          authorize?: false
        )

      assert usage.finish_reason == "tool_calls"
    end

    test "uses provider cost when available" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      model = generate(model())

      # Use UsageRecorder since cost calculation now happens there
      {:ok, usage} =
        Magus.Agents.Persistence.UsageRecorder.record(
          user_id: user.id,
          message_id: message.id,
          conversation_id: conversation.id,
          model: model,
          usage: %{"prompt_tokens" => 1000, "completion_tokens" => 500, "total_cost" => 0.002317}
        )

      # total_cost should use the provider cost from usage map
      assert Decimal.eq?(usage.total_cost, Decimal.from_float(0.002317))
    end

    test "extracts provider cost from usage map total_cost" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      model = generate(model())

      # Use UsageRecorder since cost calculation now happens there
      {:ok, usage} =
        Magus.Agents.Persistence.UsageRecorder.record(
          user_id: user.id,
          message_id: message.id,
          conversation_id: conversation.id,
          model: model,
          usage: %{"prompt_tokens" => 1000, "completion_tokens" => 500, "total_cost" => 0.005}
        )

      # total_cost should use the provider cost from usage map
      assert Decimal.eq?(usage.total_cost, Decimal.from_float(0.005))
    end

    test "calculates cost from model when provider cost not available" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

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

      # Use UsageRecorder since cost calculation now happens there
      {:ok, usage} =
        Magus.Agents.Persistence.UsageRecorder.record(
          user_id: user.id,
          message_id: message.id,
          conversation_id: conversation.id,
          model: model,
          usage: %{"prompt_tokens" => 1_000_000, "completion_tokens" => 500_000}
        )

      # 1M tokens * $1/M = $1 input, 500K tokens * $2/M = $1 output = $2 total
      assert Decimal.eq?(usage.input_cost, Decimal.new("1"))
      assert Decimal.eq?(usage.output_cost, Decimal.new("1"))
      assert Decimal.eq?(usage.total_cost, Decimal.new("2"))
    end

    test "calculates cost for image generation" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      model =
        generate(
          model(
            output_cost_value: Decimal.new("0.04"),
            output_cost_unit: :per_image
          )
        )

      # Use UsageRecorder since cost calculation now happens there
      {:ok, usage} =
        Magus.Agents.Persistence.UsageRecorder.record(
          user_id: user.id,
          message_id: message.id,
          conversation_id: conversation.id,
          model: model,
          usage: %{},
          usage_type: :image_generation
        )

      assert usage.usage_type == :image_generation
      assert Decimal.eq?(usage.output_cost, Decimal.new("0.04"))
      assert Decimal.eq?(usage.total_cost, Decimal.new("0.04"))
    end

    test "calculates cost for video generation with duration" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      model =
        generate(
          model(
            output_cost_value: Decimal.new("0.21"),
            output_cost_unit: :per_second
          )
        )

      # Use UsageRecorder since cost calculation now happens there
      {:ok, usage} =
        Magus.Agents.Persistence.UsageRecorder.record(
          user_id: user.id,
          message_id: message.id,
          conversation_id: conversation.id,
          model: model,
          usage: %{"video_duration" => 10},
          usage_type: :video_generation
        )

      assert usage.usage_type == :video_generation
      assert Decimal.eq?(usage.video_duration, Decimal.new("10"))
      # 10 seconds * $0.21/s = $2.10
      assert Decimal.eq?(usage.output_cost, Decimal.new("2.1"))
      assert Decimal.eq?(usage.total_cost, Decimal.new("2.1"))
    end
  end

  describe "billable attribute" do
    test "defaults to true for user-initiated operations" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      model = generate(model())

      {:ok, usage} =
        Magus.Agents.Persistence.UsageRecorder.record(
          user_id: user.id,
          message_id: message.id,
          conversation_id: conversation.id,
          model: model,
          usage: %{"prompt_tokens" => 100, "completion_tokens" => 50}
        )

      assert usage.billable == true
    end

    test "can be set to false for system operations" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      model = generate(model())

      {:ok, usage} =
        Magus.Agents.Persistence.UsageRecorder.record(
          user_id: user.id,
          conversation_id: conversation.id,
          model: model,
          usage: %{"prompt_tokens" => 100, "completion_tokens" => 50},
          billable: false
        )

      assert usage.billable == false
    end
  end

  describe "total_cost attribute" do
    test "total_cost is stored (not calculated)" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      model = generate(model())

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
            input_cost: Decimal.new("0.001"),
            output_cost: Decimal.new("0.002"),
            total_cost: Decimal.new("0.003")
          },
          authorize?: false
        )

      # total_cost is now a stored attribute, not a calculation
      assert Decimal.eq?(usage.total_cost, Decimal.new("0.003"))
    end
  end
end
