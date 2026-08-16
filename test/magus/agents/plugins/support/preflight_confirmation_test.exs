defmodule Magus.Agents.Plugins.Support.PreflightConfirmationTest do
  @moduledoc """
  Task 4 (signup-abuse-hardening): gate agent turns on email confirmation.

  Off by default (`:require_confirmed_email_for_agent_use`). When enabled, an
  unconfirmed acting user (the sender of the triggering message, owner
  fallback for autonomous turns — see `Helpers.acting_user_id/2`) is blocked
  before any LLM call, on the same override/event rails the usage-limit and
  hard-stop blocks use (see `PreflightHardstopTest`).

  Driven end-to-end through `Preflight.build_react_signal/3` with the same
  heavyweight scaffolding those tests use (active subscription, real
  conversation, full context assembly).
  """
  use Magus.DataCase, async: false

  import Magus.Generators
  require Ash.Query

  alias Magus.Agents.Plugins.Support.Preflight

  @noop Jido.Actions.Control.Noop
  @gate_key :require_confirmed_email_for_agent_use

  setup do
    original = Application.get_env(:magus, @gate_key)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:magus, @gate_key)
      else
        Application.put_env(:magus, @gate_key, original)
      end
    end)

    :ok
  end

  defp ensure_active_subscription(user) do
    plan = generate(usage_plan())

    {:ok, _subscription} =
      Magus.Usage.create_user_subscription(
        %{user_id: user.id, usage_plan_id: plan.id, status: :active},
        authorize?: false
      )

    :ok
  end

  defp build_agent(conversation, user, model_key) do
    %{
      id: "conv:#{conversation.id}",
      state: %{
        conversation_id: conversation.id,
        user_id: user.id,
        mode: :chat,
        model_keys: %{chat: model_key},
        __strategy__: %{}
      }
    }
  end

  defp seed_user_message(conversation, user) do
    msg = generate(message(actor: user, conversation_id: conversation.id, text: "hello"))
    msg.id
  end

  defp make_signal(payload), do: Jido.Signal.new!("message.user", payload)

  defp confirmation_events(conversation_id) do
    Magus.Chat.Message
    |> Ash.Query.filter(conversation_id == ^conversation_id and message_type == :event)
    |> Ash.read!(authorize?: false)
  end

  describe "gate enabled" do
    setup do
      Application.put_env(:magus, @gate_key, true)

      owner = confirmed_user_fixture()
      :ok = ensure_active_subscription(owner)
      model = generate(model())

      %{owner: owner, model_key: model.key}
    end

    test "unconfirmed acting user is blocked: overridden with Noop, event persisted, no LLM signal",
         %{owner: owner, model_key: model_key} do
      # The owner itself is confirmed above, but the ACTOR under test is a
      # separate unconfirmed sender so the block is exercised against the
      # acting user, not vacuously against a pre-confirmed owner.
      sender = unconfirmed_user_fixture()

      conversation = generate(conversation(actor: owner))

      {:ok, sender_message} =
        Magus.Chat.create_message(
          %{text: "hi", conversation_id: conversation.id, mode: :chat},
          actor: sender,
          authorize?: false
        )

      agent = build_agent(conversation, owner, model_key)
      signal = make_signal(%{text: "hi", message_id: sender_message.id, mode: :chat})

      assert {:ok, {:override, @noop}} = Preflight.build_react_signal(signal, agent, :chat)

      assert [event] = confirmation_events(conversation.id)
      assert event.text =~ "confirm your email"
    end

    test "confirmed acting user continues normally", %{owner: owner, model_key: model_key} do
      conversation = generate(conversation(actor: owner))
      message_id = seed_user_message(conversation, owner)
      agent = build_agent(conversation, owner, model_key)

      signal = make_signal(%{text: "hi", message_id: message_id, mode: :chat})

      assert {:ok, {:continue, _react_signal}} =
               Preflight.build_react_signal(signal, agent, :chat)

      assert confirmation_events(conversation.id) == []
    end

    test "shared conversation: unconfirmed acting member is blocked even though the owner is confirmed",
         %{owner: owner, model_key: model_key} do
      member = unconfirmed_user_fixture()

      conversation = generate(conversation(actor: owner))

      {:ok, member_message} =
        Magus.Chat.create_message(
          %{text: "hi from member", conversation_id: conversation.id, mode: :chat},
          actor: member,
          authorize?: false
        )

      # Agent state carries the owner (autonomous-turn fallback), but the
      # acting user resolves to the message sender: the unconfirmed member.
      agent = build_agent(conversation, owner, model_key)
      signal = make_signal(%{text: "continue", message_id: member_message.id, mode: :chat})

      assert {:ok, {:override, @noop}} = Preflight.build_react_signal(signal, agent, :chat)
      assert [_event] = confirmation_events(conversation.id)
    end

    test "acting user that fails to load fails closed with the confirmation event (no KeyError)",
         %{owner: owner, model_key: model_key} do
      conversation = generate(conversation(actor: owner))

      # No real user backs this id — simulates a deleted/reaped sender racing
      # a recovery replay. `Preflight.load_user_for_limits/1` falls back to a
      # bare map for it; the gate must fail closed (block) instead of
      # crashing on `user.confirmed_at` when the fallback lacks that key.
      ghost_id = Ash.UUID.generate()
      agent = build_agent(conversation, %{id: ghost_id}, model_key)

      signal = make_signal(%{text: "hi", message_id: nil, mode: :chat})

      assert {:ok, {:override, @noop}} = Preflight.build_react_signal(signal, agent, :chat)

      assert [event] = confirmation_events(conversation.id)
      assert event.text =~ "confirm your email"
    end
  end

  describe "gate disabled (default)" do
    test "unconfirmed acting user continues normally" do
      assert Application.get_env(:magus, :require_confirmed_email_for_agent_use, false) == false

      owner = unconfirmed_user_fixture()
      :ok = ensure_active_subscription(owner)
      model = generate(model())

      conversation = generate(conversation(actor: owner))
      message_id = seed_user_message(conversation, owner)
      agent = build_agent(conversation, owner, model.key)

      signal = make_signal(%{text: "hi", message_id: message_id, mode: :chat})

      assert {:ok, {:continue, _react_signal}} =
               Preflight.build_react_signal(signal, agent, :chat)

      assert confirmation_events(conversation.id) == []
    end
  end

  describe "MediaBypass image-generation gate" do
    # `message.user` in image/video mode never reaches Preflight.build_react_signal/3
    # (InboundPlugin routes it to MediaBypass.handle/3 instead — see
    # lib/magus/agents/plugins/inbound_plugin.ex), so the confirmation gate has
    # its own call site there, on the SAME subject rule (the acting member —
    # Helpers.acting_user_id/2 — not the conversation owner / state[:user_id],
    # which stays the spend gate's subject, untouched by this gate).
    alias Magus.Agents.Plugins.Support.MediaBypass

    defp media_agent(conversation, owner) do
      %{
        id: "conv:#{conversation.id}",
        state: %{
          conversation_id: conversation.id,
          user_id: owner.id,
          mode: :image_generation,
          # :auto carries no requested_selection, so resolution never
          # degrades regardless of whether an image_default role is seeded —
          # these tests exercise the confirmation gate, not model resolution.
          model_keys: %{chat: :auto, image: :auto},
          __strategy__: %{}
        }
      }
    end

    test "gate on + unconfirmed acting sender is blocked before generation, even with a confirmed owner" do
      Application.put_env(:magus, @gate_key, true)

      owner = confirmed_user_fixture()
      conversation = generate(conversation(actor: owner))

      # The owner is confirmed; the SENDER (acting user) is not. If the gate
      # incorrectly read state[:user_id] (the owner) instead of the acting
      # member, this turn would wrongly proceed.
      sender = unconfirmed_user_fixture()

      {:ok, sender_message} =
        Magus.Chat.create_message(
          %{text: "draw a cat", conversation_id: conversation.id, mode: :image_generation},
          actor: sender,
          authorize?: false
        )

      agent = media_agent(conversation, owner)

      signal =
        make_signal(%{text: "draw a cat", message_id: sender_message.id, mode: :image_generation})

      assert {:ok, {:override, @noop}} = MediaBypass.handle(signal, agent, :image_generation)

      assert [event] = confirmation_events(conversation.id)
      assert event.text =~ "confirm your email"
    end

    test "gate on + confirmed acting user proceeds past the confirmation gate" do
      Application.put_env(:magus, @gate_key, true)

      owner = confirmed_user_fixture()
      conversation = generate(conversation(actor: owner))

      message =
        generate(
          message(
            actor: owner,
            conversation_id: conversation.id,
            text: "draw a cat",
            mode: :image_generation
          )
        )

      agent = media_agent(conversation, owner)
      signal = make_signal(%{text: "draw a cat", message_id: message.id, mode: :image_generation})

      assert {:ok, {:override, @noop}} = MediaBypass.handle(signal, agent, :image_generation)

      # No active subscription is granted, so it proceeds past the
      # confirmation gate straight into the pre-existing spend gate
      # (mode_disabled — image generation isn't enabled with no plan),
      # never a real MediaGenerator call. This proves it passed the
      # confirmation check without hitting the network.
      events = confirmation_events(conversation.id)
      refute Enum.any?(events, &(&1.text =~ "confirm your email"))
      assert Enum.any?(events, &(&1.text =~ "not available on your current plan"))
    end

    test "gate off (default) + unconfirmed acting user proceeds past the confirmation gate" do
      owner = unconfirmed_user_fixture()
      conversation = generate(conversation(actor: owner))

      message =
        generate(
          message(
            actor: owner,
            conversation_id: conversation.id,
            text: "draw a cat",
            mode: :image_generation
          )
        )

      agent = media_agent(conversation, owner)
      signal = make_signal(%{text: "draw a cat", message_id: message.id, mode: :image_generation})

      assert {:ok, {:override, @noop}} = MediaBypass.handle(signal, agent, :image_generation)

      events = confirmation_events(conversation.id)
      refute Enum.any?(events, &(&1.text =~ "confirm your email"))
      assert Enum.any?(events, &(&1.text =~ "not available on your current plan"))
    end
  end
end
