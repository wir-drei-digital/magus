defmodule Magus.Agents.Persistence.UsageRecorderTest do
  @moduledoc """
  Tests for UsageRecorder module.
  """
  # async: false — these tests seed the process-global FxRates cache.
  use Magus.ResourceCase, async: false
  use Oban.Testing, repo: Magus.Repo

  alias Magus.Agents.Persistence.UsageRecorder
  alias Magus.Chat
  alias Magus.Usage
  alias Magus.Usage.MeteringSink

  # A metering-sink double that captures forwarded charges to the test process,
  # so the core UsageRecorder is tested against the Magus.Usage.MeteringSink seam
  # contract rather than the billing-edition Oban worker. The billing impl's
  # enqueue/skip decisions are covered in test/magus/billing/metering_sink_test.exs.
  defmodule CapturingSink do
    @behaviour Magus.Usage.MeteringSink

    @impl true
    def report_charge(charge) do
      if pid = Application.get_env(:magus, :usage_recorder_test_pid) do
        send(pid, {:reported_charge, charge})
      end

      :ok
    end
  end

  describe "record/1" do
    test "records usage with all fields" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      model = generate(model())

      assert {:ok, usage} =
               UsageRecorder.record(
                 user_id: user.id,
                 message_id: message.id,
                 conversation_id: conversation.id,
                 model: model,
                 usage: %{"prompt_tokens" => 100, "completion_tokens" => 50},
                 finish_reason: :stop,
                 usage_type: :response
               )

      assert usage.prompt_tokens == 100
      assert usage.completion_tokens == 50
      assert usage.finish_reason == "stop"
      assert usage.usage_type == :response
    end

    test "returns {:ok, :skipped} when model is nil" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      assert {:ok, :skipped} =
               UsageRecorder.record(
                 user_id: user.id,
                 message_id: message.id,
                 conversation_id: conversation.id,
                 model: nil
               )
    end

    test "returns {:ok, :skipped} when both model and model_key are nil" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      assert {:ok, :skipped} =
               UsageRecorder.record(
                 user_id: user.id,
                 message_id: message.id,
                 conversation_id: conversation.id,
                 model: nil,
                 model_key: nil
               )
    end

    test "normalizes atom finish_reason to string" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      model = generate(model())

      assert {:ok, usage} =
               UsageRecorder.record(
                 user_id: user.id,
                 message_id: message.id,
                 conversation_id: conversation.id,
                 model: model,
                 finish_reason: :tool_calls
               )

      assert usage.finish_reason == "tool_calls"
    end

    test "passes string finish_reason through unchanged" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      model = generate(model())

      assert {:ok, usage} =
               UsageRecorder.record(
                 user_id: user.id,
                 message_id: message.id,
                 conversation_id: conversation.id,
                 model: model,
                 finish_reason: "content_filter"
               )

      assert usage.finish_reason == "content_filter"
    end

    test "extracts provider cost from usage map" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      model = generate(model())

      assert {:ok, usage} =
               UsageRecorder.record(
                 user_id: user.id,
                 message_id: message.id,
                 conversation_id: conversation.id,
                 model: model,
                 usage: %{"total_cost" => 0.002317}
               )

      assert Decimal.eq?(usage.total_cost, Decimal.from_float(0.002317))
    end
  end

  describe "record!/1" do
    test "returns :ok on success" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      model = generate(model())

      assert :ok =
               UsageRecorder.record!(
                 user_id: user.id,
                 message_id: message.id,
                 conversation_id: conversation.id,
                 model: model
               )
    end

    test "returns :ok when skipped" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      assert :ok =
               UsageRecorder.record!(
                 user_id: user.id,
                 message_id: message.id,
                 conversation_id: conversation.id,
                 model: nil
               )
    end
  end

  describe "usage_type_for_mode/1" do
    test "maps chat to response" do
      assert UsageRecorder.usage_type_for_mode(:chat) == :response
    end

    test "maps search to search" do
      assert UsageRecorder.usage_type_for_mode(:search) == :search
    end

    test "maps reasoning to response" do
      assert UsageRecorder.usage_type_for_mode(:reasoning) == :response
    end

    test "maps image_generation to image_generation" do
      assert UsageRecorder.usage_type_for_mode(:image_generation) == :image_generation
    end

    test "maps video_generation to video_generation" do
      assert UsageRecorder.usage_type_for_mode(:video_generation) == :video_generation
    end

    test "maps unknown modes to response" do
      assert UsageRecorder.usage_type_for_mode(:unknown) == :response
    end
  end

  describe "model_key resolution" do
    test "looks up model by key when model struct not provided" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      # Create a model with a specific key
      model = generate(model(key: "test-provider/test-model-123"))

      assert {:ok, usage} =
               UsageRecorder.record(
                 user_id: user.id,
                 message_id: message.id,
                 conversation_id: conversation.id,
                 model_key: "test-provider/test-model-123",
                 usage: %{"prompt_tokens" => 100, "completion_tokens" => 50}
               )

      # Should have looked up the model and used its id and name
      assert usage.model_id == model.id
      assert usage.model_name == model.name
      assert usage.prompt_tokens == 100
      assert usage.completion_tokens == 50
    end

    test "uses model_key as model_name when model not in database" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      assert {:ok, usage} =
               UsageRecorder.record(
                 user_id: user.id,
                 message_id: message.id,
                 conversation_id: conversation.id,
                 model_key: "nonexistent/model-key",
                 usage: %{"prompt_tokens" => 50}
               )

      # Should record with model_key as name and nil model_id
      assert usage.model_id == nil
      assert usage.model_name == "nonexistent/model-key"
      assert usage.prompt_tokens == 50
    end

    test "model struct takes precedence over model_key" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      # Create two models
      model_from_struct = generate(model(key: "provider/model-struct", name: "Model From Struct"))
      _model_from_key = generate(model(key: "provider/model-key", name: "Model From Key"))

      assert {:ok, usage} =
               UsageRecorder.record(
                 user_id: user.id,
                 message_id: message.id,
                 conversation_id: conversation.id,
                 model: model_from_struct,
                 model_key: "provider/model-key"
               )

      # Should use the model struct, not look up by key
      assert usage.model_id == model_from_struct.id
      assert usage.model_name == "Model From Struct"
    end

    test "calculates costs when model found by key" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      # Create a model with known pricing: $1/M input, $2/M output
      _model =
        generate(
          model(
            key: "test/priced-model",
            input_cost_value: Decimal.new("1"),
            input_cost_unit: :per_million_tokens,
            output_cost_value: Decimal.new("2"),
            output_cost_unit: :per_million_tokens
          )
        )

      assert {:ok, usage} =
               UsageRecorder.record(
                 user_id: user.id,
                 message_id: message.id,
                 conversation_id: conversation.id,
                 model_key: "test/priced-model",
                 usage: %{"prompt_tokens" => 1_000_000, "completion_tokens" => 500_000}
               )

      # 1M tokens * $1/M = $1 input, 500K tokens * $2/M = $1 output = $2 total
      assert Decimal.eq?(usage.input_cost, Decimal.new("1"))
      assert Decimal.eq?(usage.output_cost, Decimal.new("1"))
      assert Decimal.eq?(usage.total_cost, Decimal.new("2"))
    end

    test "uses zero costs when model not found by key" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      assert {:ok, usage} =
               UsageRecorder.record(
                 user_id: user.id,
                 message_id: message.id,
                 conversation_id: conversation.id,
                 model_key: "unknown/model",
                 usage: %{"prompt_tokens" => 1000, "completion_tokens" => 500}
               )

      # No model for cost calculation, so costs should be zero
      assert Decimal.eq?(usage.input_cost, Decimal.new("0"))
      assert Decimal.eq?(usage.output_cost, Decimal.new("0"))
      assert Decimal.eq?(usage.total_cost, Decimal.new("0"))
    end

    test "records billable: false for system operations" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.send_user_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      assert {:ok, usage} =
               UsageRecorder.record(
                 user_id: user.id,
                 message_id: message.id,
                 conversation_id: conversation.id,
                 model_key: "system/title-generator",
                 usage: %{"prompt_tokens" => 100},
                 billable: false
               )

      assert usage.billable == false
      assert usage.model_name == "system/title-generator"
    end
  end

  describe "extract_provider_cost/1" do
    test "returns nil for nil input" do
      assert UsageRecorder.extract_provider_cost(nil) == nil
    end

    test "returns nil for empty map" do
      assert UsageRecorder.extract_provider_cost(%{}) == nil
    end

    test "extracts float total_cost" do
      result = UsageRecorder.extract_provider_cost(%{"total_cost" => 0.002317})
      assert Decimal.eq?(result, Decimal.from_float(0.002317))
    end

    test "extracts integer total_cost" do
      result = UsageRecorder.extract_provider_cost(%{"total_cost" => 5})
      assert Decimal.eq?(result, Decimal.new(5))
    end

    test "extracts string total_cost" do
      result = UsageRecorder.extract_provider_cost(%{"total_cost" => "0.002317"})
      assert Decimal.eq?(result, Decimal.new("0.002317"))
    end

    test "extracts Decimal total_cost" do
      result = UsageRecorder.extract_provider_cost(%{"total_cost" => Decimal.new("0.002317")})
      assert Decimal.eq?(result, Decimal.new("0.002317"))
    end

    test "handles atom key total_cost" do
      result = UsageRecorder.extract_provider_cost(%{total_cost: 0.005})
      assert Decimal.eq?(result, Decimal.from_float(0.005))
    end

    test "returns nil for invalid string" do
      assert UsageRecorder.extract_provider_cost(%{"total_cost" => "invalid"}) == nil
    end
  end

  describe "extract_provider_cost/1 inline cost" do
    test "reads OpenRouter inline cost (float)" do
      assert Decimal.equal?(
               UsageRecorder.extract_provider_cost(%{"cost" => 0.136}),
               Decimal.from_float(0.136)
             )
    end

    test "reads cost from atom key" do
      assert Decimal.equal?(
               UsageRecorder.extract_provider_cost(%{cost: 0.25}),
               Decimal.from_float(0.25)
             )
    end

    test "reads cost as a string" do
      assert Decimal.equal?(
               UsageRecorder.extract_provider_cost(%{"cost" => "0.42"}),
               Decimal.new("0.42")
             )
    end

    test "prefers total_cost over cost when both are present" do
      assert Decimal.equal?(
               UsageRecorder.extract_provider_cost(%{"total_cost" => 0.1, "cost" => 0.2}),
               Decimal.from_float(0.1)
             )
    end

    test "returns nil when neither key is present" do
      assert UsageRecorder.extract_provider_cost(%{"prompt_tokens" => 10}) == nil
    end
  end

  describe "record_billable_cost/3 charge forwarding" do
    setup do
      test_pid = self()
      prev_rate = Application.get_env(:magus, Magus.Usage.ExchangeRate)
      prev_sink = Application.get_env(:magus, MeteringSink)
      prev_pid = Application.get_env(:magus, :usage_recorder_test_pid)

      # 1 USD = 1 CHF via the core Identity default (deterministic), and capture
      # the forwarded charge through the seam instead of the billing Oban worker.
      Application.put_env(:magus, Magus.Usage.ExchangeRate,
        impl: Magus.Usage.ExchangeRate.Identity
      )

      Application.put_env(:magus, MeteringSink, impl: CapturingSink)
      Application.put_env(:magus, :usage_recorder_test_pid, test_pid)

      on_exit(fn ->
        restore(:magus, Magus.Usage.ExchangeRate, prev_rate)
        restore(:magus, MeteringSink, prev_sink)
        restore(:magus, :usage_recorder_test_pid, prev_pid)
      end)

      :ok
    end

    test "billable usage forwards a charge carrying both Stripe ids" do
      user = create_actor()
      _sub = billable_subscription(user, "cus_1")

      :ok =
        UsageRecorder.record_billable_cost(user.id, Decimal.new("0.50"),
          meter_identifier: "usage-1"
        )

      assert_received {:reported_charge,
                       %MeteringSink.Charge{
                         stripe_customer_id: "cus_1",
                         stripe_subscription_id: "sub_default",
                         overflow_cents: 50,
                         identifier: "usage-1"
                       }}
    end

    test "free (non-billable) usage forwards no Stripe ids" do
      user = create_actor()
      _sub = free_subscription(user)

      :ok =
        UsageRecorder.record_billable_cost(user.id, Decimal.new("0.50"),
          meter_identifier: "usage-2"
        )

      assert_received {:reported_charge,
                       %MeteringSink.Charge{
                         stripe_customer_id: nil,
                         stripe_subscription_id: nil,
                         identifier: "usage-2"
                       }}
    end

    test "missing meter identifier forwards an empty identifier" do
      user = create_actor()
      _sub = billable_subscription(user, "cus_4")

      :ok = UsageRecorder.record_billable_cost(user.id, Decimal.new("0.50"))

      assert_received {:reported_charge,
                       %MeteringSink.Charge{stripe_customer_id: "cus_4", identifier: ""}}
    end

    test "a customer without a stripe_subscription_id forwards a nil subscription id" do
      user = create_actor()
      _sub = customer_only_subscription(user, "cus_5")

      :ok =
        UsageRecorder.record_billable_cost(user.id, Decimal.new("0.50"),
          meter_identifier: "usage-5"
        )

      assert_received {:reported_charge,
                       %MeteringSink.Charge{
                         stripe_customer_id: "cus_5",
                         stripe_subscription_id: nil,
                         identifier: "usage-5"
                       }}
    end
  end

  describe "record_billable_cost/3 usage-changed broadcast" do
    setup do
      prev_rate = Application.get_env(:magus, Magus.Usage.ExchangeRate)

      Application.put_env(:magus, Magus.Usage.ExchangeRate,
        impl: Magus.Usage.ExchangeRate.Identity
      )

      on_exit(fn -> restore(:magus, Magus.Usage.ExchangeRate, prev_rate) end)
      :ok
    end

    test "broadcasts usage_changed to the user's workbench topic after a successful deduction" do
      user = create_actor()
      _sub = billable_subscription(user, "cus_bc")

      Phoenix.PubSub.subscribe(
        Magus.PubSub,
        MagusWeb.Workbench.Signals.workbench_user_topic(user.id)
      )

      :ok =
        UsageRecorder.record_billable_cost(user.id, Decimal.new("0.50"),
          meter_identifier: "usage-bc"
        )

      # The workbench shell listens on this topic and recomputes its PAYG
      # usage indicator on receipt, keeping spent/wallet/tokens fresh.
      assert_receive {:workbench_user, :usage_changed}
    end

    test "does not broadcast when there is nothing to deduct (zero cost)" do
      user = create_actor()
      _sub = billable_subscription(user, "cus_zero")

      Phoenix.PubSub.subscribe(
        Magus.PubSub,
        MagusWeb.Workbench.Signals.workbench_user_topic(user.id)
      )

      :ok = UsageRecorder.record_billable_cost(user.id, Decimal.new("0"))

      refute_receive {:workbench_user, :usage_changed}
    end
  end

  # Build a billable PAYG subscription for `user`; usage accrues straight into
  # the postpaid period accumulator. A billable sub carries
  # BOTH a stripe_customer_id and a stripe_subscription_id (the metered item
  # lives on the subscription); the meter reporter only fires when both are set.
  defp billable_subscription(user, customer_id, subscription_id \\ "sub_default") do
    plan = ensure_payg_plan()

    Usage.Account
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_id: user.id,
        usage_plan_id: plan.id,
        status: :active,
        stripe_customer_id: customer_id,
        stripe_subscription_id: subscription_id,
        storage_usage_bytes: 0
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  # Build a subscription that has a stripe_customer_id but NO
  # stripe_subscription_id — a customer exists, but there is no metered
  # subscription item to bill against, so no meter event must be reported.
  defp customer_only_subscription(user, customer_id) do
    plan = ensure_payg_plan()

    Usage.Account
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_id: user.id,
        usage_plan_id: plan.id,
        status: :active,
        stripe_customer_id: customer_id,
        storage_usage_bytes: 0
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  # Build a free subscription (no stripe_customer_id) for `user`.
  defp free_subscription(user) do
    plan = ensure_free_plan()

    Usage.Account
    |> Ash.Changeset.for_create(
      :create,
      %{user_id: user.id, usage_plan_id: plan.id, status: :active, storage_usage_bytes: 0},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
