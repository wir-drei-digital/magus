defmodule Magus.Agents.Plugins.Support.PreflightTest do
  @moduledoc """
  Verifies that Preflight threads `run_source` from the `message.user` payload
  through to the LLM context Builder as `selections[:source]`, so the
  WakeupPreamble fires for `:heartbeat` and `:manual_trigger` runs.
  """
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Agents.Plugins.Support.Preflight

  # The Builder prepends the wakeup preamble only when source is :heartbeat
  # or :manual_trigger, so we look for a phrase from that preamble.
  @preamble_marker "list_inbox_events"

  defp ensure_active_subscription(user) do
    plan = generate(usage_plan())

    {:ok, _subscription} =
      Magus.Usage.create_user_subscription(
        %{user_id: user.id, usage_plan_id: plan.id, status: :active},
        authorize?: false
      )

    :ok
  end

  defp build_agent(conversation, user) do
    %{
      id: "conv:#{conversation.id}",
      state: %{
        conversation_id: conversation.id,
        user_id: user.id,
        mode: :chat,
        model_keys: %{chat: "openrouter:x-ai/grok-4.1-fast"},
        __strategy__: %{}
      }
    }
  end

  defp make_signal(payload) do
    Jido.Signal.new!("message.user", payload)
  end

  describe "run_source threading" do
    setup do
      user = generate(user())
      :ok = ensure_active_subscription(user)
      agent = custom_agent(user, %{heartbeat_default_interval_minutes: 60})
      conversation = generate(conversation(actor: user, custom_agent_id: agent.id))

      %{user: user, agent: agent, conversation: conversation}
    end

    test "heartbeat run_source string produces a system_prompt with the wakeup preamble", %{
      user: user,
      conversation: conversation
    } do
      jido_agent = build_agent(conversation, user)

      signal =
        make_signal(%{
          text: "wake up",
          message_id: Ash.UUIDv7.generate(),
          mode: :chat,
          run_source: "heartbeat"
        })

      assert {:ok, {:continue, react_signal}} =
               Preflight.build_react_signal(signal, jido_agent, :chat)

      assert react_signal.data.system_prompt =~ @preamble_marker
    end

    test "manual_trigger run_source string produces a system_prompt with the wakeup preamble",
         %{user: user, conversation: conversation} do
      jido_agent = build_agent(conversation, user)

      signal =
        make_signal(%{
          text: "manual run",
          message_id: Ash.UUIDv7.generate(),
          mode: :chat,
          run_source: "manual_trigger"
        })

      assert {:ok, {:continue, react_signal}} =
               Preflight.build_react_signal(signal, jido_agent, :chat)

      assert react_signal.data.system_prompt =~ @preamble_marker
    end

    test "absent run_source does not inject the wakeup preamble", %{
      user: user,
      conversation: conversation
    } do
      jido_agent = build_agent(conversation, user)

      signal =
        make_signal(%{
          text: "hello",
          message_id: Ash.UUIDv7.generate(),
          mode: :chat
        })

      assert {:ok, {:continue, react_signal}} =
               Preflight.build_react_signal(signal, jido_agent, :chat)

      refute react_signal.data.system_prompt =~ @preamble_marker
    end

    test "unknown run_source string falls back to no preamble (no atom blowup)", %{
      user: user,
      conversation: conversation
    } do
      jido_agent = build_agent(conversation, user)

      signal =
        make_signal(%{
          text: "hello",
          message_id: Ash.UUIDv7.generate(),
          mode: :chat,
          run_source: "this_is_not_a_real_source_zzzzz"
        })

      assert {:ok, {:continue, react_signal}} =
               Preflight.build_react_signal(signal, jido_agent, :chat)

      refute react_signal.data.system_prompt =~ @preamble_marker
    end
  end

  describe "assemble_context/2 (inspection)" do
    test "returns the system prompt and appends the simulated text as the final turn" do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      assert {:ok, result} =
               Preflight.assemble_context(conversation.id,
                 text: "hello there",
                 model_key: "openrouter:x-ai/grok-4.1-fast"
               )

      rc = result.request_context
      assert is_binary(rc.system_prompt) and rc.system_prompt != ""
      assert is_list(rc.initial_messages)

      # The simulated text is appended as the final user turn.
      last = List.last(rc.initial_messages)
      assert last.role == :user

      rendered_text =
        last.content
        |> List.wrap()
        |> Enum.map(&Map.get(&1, :text))
        |> Enum.filter(&is_binary/1)
        |> Enum.join(" ")

      assert rendered_text =~ "hello there"
    end

    test "llm_opts carry openrouter_session_id equal to the conversation id (sticky routing)" do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      assert {:ok, result} =
               Preflight.assemble_context(conversation.id,
                 text: "hello there",
                 model_key: "openrouter:x-ai/grok-4.1-fast"
               )

      llm_opts = result.request_context.llm_opts

      assert get_llm_opt(llm_opts, :openrouter_session_id) == conversation.id
    end
  end

  # Read both map- and list-shaped llm_opts (the strategy accepts either).
  defp get_llm_opt(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp get_llm_opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp get_llm_opt(_opts, _key), do: nil

  describe "companion_brain_hints/1" do
    test "resolves a brain-page companion to {brain_id, page_id}" do
      user = generate(user())
      {:ok, brain} = Magus.Brain.create_brain(%{title: "Hints"}, actor: user)
      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Page"}, actor: user)

      {:ok, conv} =
        Magus.Chat.find_or_create_companion_conversation(:brain_page, page.id, actor: user)

      # A companion chat IS the brain pane: the tools get the pane hints
      # without the client threading brain metadata on every message.
      assert {brain_id, page_id} = Preflight.companion_brain_hints(conv)
      assert brain_id == brain.id
      assert page_id == page.id
    end

    test "returns {nil, nil} for a plain conversation" do
      user = generate(user())
      {:ok, conv} = Magus.Chat.create_conversation(%{title: "Plain"}, actor: user)

      assert {nil, nil} = Preflight.companion_brain_hints(conv)
    end

    test "returns {nil, nil} for a file companion" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, file} =
        Magus.Files.create_file(
          %{
            name: "doc.pdf",
            type: :document,
            mime_type: "application/pdf",
            file_size: 1,
            file_path: "#{user.id}/#{Ash.UUIDv7.generate()}.pdf",
            workspace_id: ws.id
          },
          actor: user
        )

      {:ok, conv} =
        Magus.Chat.find_or_create_companion_conversation(:file, file.id, actor: user)

      assert {nil, nil} = Preflight.companion_brain_hints(conv)
    end

    test "returns {nil, nil} once the companion page is trashed" do
      user = generate(user())
      {:ok, brain} = Magus.Brain.create_brain(%{title: "Hints"}, actor: user)
      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Gone"}, actor: user)

      {:ok, conv} =
        Magus.Chat.find_or_create_companion_conversation(:brain_page, page.id, actor: user)

      {:ok, _} = Magus.Brain.soft_delete_page(page, actor: user)

      assert {nil, nil} = Preflight.companion_brain_hints(conv)
    end
  end

  describe "explicit_brain_refs/1" do
    test "page-only metadata resolves the brain id server-side" do
      user = generate(user())
      {:ok, brain} = Magus.Brain.create_brain(%{title: "Docked"}, actor: user)
      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Pane"}, actor: user)

      # The SPA's docked companion pane sends only brain_page_id (the
      # CompanionSpec carries no brain id).
      assert {brain_id, page_id} = Preflight.explicit_brain_refs(%{"brain_page_id" => page.id})
      assert brain_id == brain.id
      assert page_id == page.id
    end

    test "explicit brain_id passes through untouched" do
      assert {"b-1", "p-1"} =
               Preflight.explicit_brain_refs(%{"brain_id" => "b-1", "brain_page_id" => "p-1"})
    end

    test "no refs and unresolvable page both yield {nil, nil}" do
      assert {nil, nil} = Preflight.explicit_brain_refs(%{})

      assert {nil, _} = Preflight.explicit_brain_refs(%{"brain_page_id" => Ash.UUIDv7.generate()})
    end
  end
end
