defmodule Magus.Agents.Plugins.Support.PreflightHardstopTest do
  @moduledoc """
  Phase 2b-2b Task 1: a broken EXPLICIT model selection (one that
  `Magus.Models.Resolution.degraded?/1` flags) must hard-stop the turn in
  Preflight before any LLM call, on the same error/event rails the usage-limit
  and region-unavailable blocks use.

  Driven end-to-end through `Preflight.build_react_signal/3` with the same
  heavyweight scaffolding `PreflightTest` uses (active subscription, real
  conversation, full context assembly). The block returns the Noop override
  and persists a machine-readable `:event` message whose `tool_call_data`
  carries the STRING-keyed payload the SPA consumes verbatim.
  """
  use Magus.DataCase, async: false

  import Magus.Generators
  require Ash.Query

  alias Magus.Agents.Plugins.Support.Preflight

  @noop Jido.Actions.Control.Noop

  defp ensure_active_subscription(user) do
    plan = generate(usage_plan())

    {:ok, _subscription} =
      Magus.Usage.create_user_subscription(
        %{user_id: user.id, usage_plan_id: plan.id, status: :active},
        authorize?: false
      )

    :ok
  end

  defp build_agent(conversation, user, model_keys) do
    %{
      id: "conv:#{conversation.id}",
      state: %{
        conversation_id: conversation.id,
        user_id: user.id,
        mode: :chat,
        model_keys: model_keys,
        __strategy__: %{}
      }
    }
  end

  # A real user message so acting_user_id resolves to the sender and the
  # broken-selection event attaches to a real turn.
  defp seed_user_message(conversation, user) do
    msg = generate(message(actor: user, conversation_id: conversation.id, text: "hello"))
    msg.id
  end

  defp make_signal(payload), do: Jido.Signal.new!("message.user", payload)

  defp broken_selection_events(conversation_id) do
    Magus.Chat.Message
    |> Ash.Query.filter(conversation_id == ^conversation_id and message_type == :event)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(fn m ->
      is_map(m.tool_call_data) and m.tool_call_data["kind"] == "broken_model_selection"
    end)
  end

  setup do
    # Deliberately do NOT clear the catalog: the seeded chat_default role must
    # exist so a degraded `by: :key` selection resolves to a fallback WITH a key
    # (the payload's `fallback_key`). In production the catalog is never empty.
    owner = generate(user())
    :ok = ensure_active_subscription(owner)

    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "anthropic", api_key: "sk"},
        actor: owner
      )

    {:ok, model} =
      Magus.Chat.create_owned_model(
        %{name: "C", model_id: "claude-x", model_provider_id: provider.id},
        actor: owner
      )

    %{owner: owner, provider: provider, model: model}
  end

  describe "conversation-scoped broken selection (selected_model_id)" do
    test "owner pins their owned model, model is destroyed -> blocked with scope conversation",
         %{owner: owner, model: model} do
      conversation =
        generate(conversation(actor: owner, selected_model_id: model.id))

      message_id = seed_user_message(conversation, owner)
      stale_id = model.id

      # Unpin the conversation FK (nilify) so the referenced model can be
      # destroyed, then destroy it. The signal still carries the now-stale id
      # (as the SPA would while its selection is in flight), so the explicit
      # by-id selection degrades to the inherited fallback.
      {:ok, conversation} =
        Magus.Chat.set_conversation_model(conversation, %{selected_model_id: nil}, actor: owner)

      :ok = Ash.destroy!(model, action: :destroy_owned, actor: owner)

      agent = build_agent(conversation, owner, %{chat: :auto})

      signal =
        make_signal(%{
          text: "continue",
          message_id: message_id,
          mode: :chat,
          selected_model_id: stale_id
        })

      assert {:ok, {:override, @noop}} =
               Preflight.build_react_signal(signal, agent, :chat)

      assert [event] = broken_selection_events(conversation.id)
      payload = event.tool_call_data

      assert payload["kind"] == "broken_model_selection"
      assert payload["requested_by"] == "id"
      assert payload["requested_value"] == stale_id
      assert payload["scope"] == "conversation"
      assert is_binary(payload["fallback_key"]) and payload["fallback_key"] != ""
    end
  end

  describe "user-scoped broken selection (stale user default key)" do
    test "conversation selection nil, stale user-default key -> blocked with scope user",
         %{owner: owner} do
      conversation = generate(conversation(actor: owner, selected_model_id: nil))
      message_id = seed_user_message(conversation, owner)

      stale_key = "openrouter:vendor/removed-model-#{System.unique_integer([:positive])}"
      agent = build_agent(conversation, owner, %{chat: stale_key})

      signal =
        make_signal(%{
          text: "continue",
          message_id: message_id,
          mode: :chat
        })

      assert {:ok, {:override, @noop}} =
               Preflight.build_react_signal(signal, agent, :chat)

      assert [event] = broken_selection_events(conversation.id)
      payload = event.tool_call_data

      assert payload["kind"] == "broken_model_selection"
      assert payload["requested_by"] == "key"
      assert payload["requested_value"] == stale_key
      assert payload["scope"] == "user"
      assert is_binary(payload["fallback_key"]) and payload["fallback_key"] != ""
    end
  end

  describe "behavior-neutral paths (no requested_selection)" do
    test ":auto chat key is NOT blocked", %{owner: owner} do
      conversation = generate(conversation(actor: owner, selected_model_id: nil))
      message_id = seed_user_message(conversation, owner)
      agent = build_agent(conversation, owner, %{chat: :auto})

      signal = make_signal(%{text: "hi", message_id: message_id, mode: :chat})

      assert {:ok, {:continue, _react_signal}} =
               Preflight.build_react_signal(signal, agent, :chat)

      assert broken_selection_events(conversation.id) == []
    end

    test "a resolvable explicit key is NOT blocked", %{owner: owner} do
      conversation = generate(conversation(actor: owner, selected_model_id: nil))
      message_id = seed_user_message(conversation, owner)

      # A real, resolvable catalog key: resolution is :explicit, not degraded.
      good = generate(model())
      agent = build_agent(conversation, owner, %{chat: good.key})

      signal = make_signal(%{text: "hi", message_id: message_id, mode: :chat})

      assert {:ok, {:continue, _react_signal}} =
               Preflight.build_react_signal(signal, agent, :chat)

      assert broken_selection_events(conversation.id) == []
    end
  end

  describe "multiplayer sender-scoped block" do
    test "sender B pinned on A's owned model -> blocked with scope conversation", %{
      owner: owner_a,
      model: model_a
    } do
      # A pins their owned model at the conversation level, then B sends a
      # message. B (the sender) cannot see A's owned model, so resolution
      # degrades for B and the turn is blocked, scoped to the conversation.
      user_b = generate(user())

      conversation =
        generate(conversation(actor: owner_a, selected_model_id: model_a.id))

      # B sends the triggering message (created actor-scoped but with
      # authorization off: membership/observer policy is not what this test
      # exercises — the block is). acting_user_id then resolves to B, the sender.
      {:ok, b_message} =
        Magus.Chat.create_message(
          %{text: "hi from B", conversation_id: conversation.id, mode: :chat},
          actor: user_b,
          authorize?: false
        )

      message_id = b_message.id

      # Agent owner is A, but the sender (B) is the resolver actor.
      agent = build_agent(conversation, owner_a, %{chat: :auto})

      signal =
        make_signal(%{
          text: "continue",
          message_id: message_id,
          mode: :chat,
          selected_model_id: model_a.id
        })

      assert {:ok, {:override, @noop}} =
               Preflight.build_react_signal(signal, agent, :chat)

      assert [event] = broken_selection_events(conversation.id)
      payload = event.tool_call_data

      assert payload["kind"] == "broken_model_selection"
      assert payload["requested_by"] == "id"
      assert payload["requested_value"] == model_a.id
      assert payload["scope"] == "conversation"
    end
  end
end
