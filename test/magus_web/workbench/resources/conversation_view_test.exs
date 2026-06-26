defmodule MagusWeb.Workbench.Resources.ConversationViewTest do
  use MagusWeb.LiveViewCase, async: false

  import Magus.Generators
  import MagusWeb.Workbench.TestHelpers

  alias MagusWeb.Workbench.Resources.ConversationView

  describe "messages" do
    test "renders existing messages on mount" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Magus.Chat.create_conversation(
          %{title: "With messages", workspace_id: ws.id},
          actor: user
        )

      {:ok, _msg} =
        Magus.Chat.create_message(
          %{
            conversation_id: conv.id,
            text: "hello world"
          },
          actor: user
        )

      {:ok, _lv, html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          ConversationView,
          session: %{
            "conversation_id" => conv.id,
            "user_id" => user.id,
            "tab_id" => "tab_abc"
          }
        )

      assert html =~ "hello world"
    end
  end

  describe "sending a user message" do
    test "persists a user message when the form is submitted" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Magus.Chat.create_conversation(
          %{title: "Send test", workspace_id: ws.id},
          actor: user
        )

      {:ok, lv, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          ConversationView,
          session: %{
            "conversation_id" => conv.id,
            "user_id" => user.id,
            "tab_id" => "tab_abc"
          }
        )

      # The ChatInputComponent handles the form internally (phx-target=@myself),
      # then calls notify_parent({:send_message_with_resources, params, []}).
      # We simulate that notify_parent message directly to the parent LV process.
      alias MagusWeb.ChatLive.Components.ChatInput.ChatInputComponent

      send(
        lv.pid,
        {ChatInputComponent,
         {:send_message_with_resources,
          %{
            "text" => "hi from test",
            "conversation_id" => conv.id,
            "mode" => "chat",
            "selected_model_id" => nil
          }, []}}
      )

      # Poll until the async SignalAgent change persists the message.
      :ok =
        poll_until(fn ->
          messages = Magus.Chat.message_history!(conv.id, actor: user, stream?: false)
          Enum.any?(messages, fn m -> m.text == "hi from test" and m.role == :user end)
        end)
    end
  end

  describe "mount/3" do
    test "mounts with conversation loaded" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Magus.Chat.create_conversation(
          %{title: "Mount test", workspace_id: ws.id},
          actor: user
        )

      {:ok, lv, html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          ConversationView,
          session: %{
            "conversation_id" => conv.id,
            "user_id" => user.id,
            "tab_id" => "tab_abc"
          }
        )

      assert html =~ "Mount test"

      assert Phoenix.LiveViewTest.has_element?(
               lv,
               ~s([data-conversation-view][data-conversation-id="#{conv.id}"])
             )
    end
  end

  describe "tool events" do
    test "renders a tool.start event" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Magus.Chat.create_conversation(
          %{title: "Tool test", workspace_id: ws.id},
          actor: user
        )

      {:ok, lv, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          MagusWeb.Workbench.Resources.ConversationView,
          session: %{
            "conversation_id" => conv.id,
            "user_id" => user.id,
            "tab_id" => "tab_abc"
          }
        )

      # tool.start signal shape from lib/magus/agents/signals.ex broadcast_tool_start/5:
      # %{type: "tool.start", event_id: ..., tool_name: ..., display_name: ..., inputs: ...}
      MagusWeb.Endpoint.broadcast(
        "agents:#{conv.id}",
        "agent_signal",
        %{
          type: "tool.start",
          event_id: "evt_123",
          tool_name: "web_search",
          display_name: "Searching the web",
          inputs: %{"query" => "hello"}
        }
      )

      :ok =
        poll_until(fn ->
          html = Phoenix.LiveViewTest.render(lv)
          html =~ "Web Search" or html =~ "Searching the web"
        end)
    end
  end

  describe "file uploads" do
    test "allow_upload :attachments is configured with consistent limits" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Magus.Chat.create_conversation(
          %{title: "Upload test", workspace_id: ws.id},
          actor: user
        )

      {:ok, lv, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          MagusWeb.Workbench.Resources.ConversationView,
          session: %{
            "conversation_id" => conv.id,
            "user_id" => user.id,
            "tab_id" => "tab_abc"
          }
        )

      assigns = :sys.get_state(lv.pid).socket.assigns
      upload = assigns.uploads.attachments
      assert upload.max_entries == 5
      assert upload.max_file_size == 50_000_000
    end
  end

  describe "model and chat mode selection" do
    test "switching models via ModelSelectorComponent notification updates selected_model_id" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      # Create two chat models explicitly (LLMDB is not active in test env)
      model_a = generate(model())
      model_b = generate(model())

      {:ok, conv} =
        Magus.Chat.create_conversation(
          %{title: "Model test", workspace_id: ws.id},
          actor: user
        )

      {:ok, lv, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          MagusWeb.Workbench.Resources.ConversationView,
          session: %{
            "conversation_id" => conv.id,
            "user_id" => user.id,
            "tab_id" => "tab_abc"
          }
        )

      alias MagusWeb.ChatLive.Components.ChatInput.ModelSelectorComponent

      # ModelSelectorComponent uses notify_parent/1 which sends a message to the parent LV
      # with shape {ModelSelectorComponent, {:model_selected, model_id, mode, context}}
      send(lv.pid, {ModelSelectorComponent, {:model_selected, model_b.id, :chat, :main}})

      :ok =
        poll_until(fn ->
          :sys.get_state(lv.pid).socket.assigns.selected_model_id == model_b.id
        end)

      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.selected_model_id == model_b.id
      assert assigns.selected_chat_model_id == model_b.id

      # Verify model_a is still distinct so the assertion is meaningful
      assert model_a.id != model_b.id
    end

    test "switching chat mode via ModelSelectorComponent notification updates chat_mode" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Magus.Chat.create_conversation(
          %{title: "Mode test", workspace_id: ws.id},
          actor: user
        )

      {:ok, lv, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          MagusWeb.Workbench.Resources.ConversationView,
          session: %{
            "conversation_id" => conv.id,
            "user_id" => user.id,
            "tab_id" => "tab_abc"
          }
        )

      alias MagusWeb.ChatLive.Components.ChatInput.ModelSelectorComponent

      # ModelSelectorComponent uses notify_parent/1 which sends
      # {ModelSelectorComponent, {:mode_changed, new_mode, selected_model_id, context}}
      send(lv.pid, {ModelSelectorComponent, {:mode_changed, :image_generation, nil, :main}})

      :ok =
        poll_until(fn ->
          :sys.get_state(lv.pid).socket.assigns.chat_mode == :image_generation
        end)

      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.chat_mode == :image_generation
    end
  end

  describe "context-window controls" do
    test "set_context_strategy=compact persists the per-conversation override" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Magus.Chat.create_conversation(%{title: "Strategy test", workspace_id: ws.id},
          actor: user
        )

      {:ok, lv, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          ConversationView,
          session: %{
            "conversation_id" => conv.id,
            "user_id" => user.id,
            "tab_id" => "tab_ctx_strategy"
          }
        )

      lv
      |> Phoenix.LiveViewTest.element(~s([data-role="context-strategy-compact"]))
      |> Phoenix.LiveViewTest.render_click()

      {:ok, cw} = Magus.Chat.get_context_window(conv.id, actor: user)
      assert cw.strategy == :compact
    end

    test "clear_context advances the floor past the latest message so the next window is empty" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Magus.Chat.create_conversation(%{title: "Clear test", workspace_id: ws.id}, actor: user)

      {:ok, latest} =
        Magus.Chat.create_message(%{conversation_id: conv.id, text: "newest"}, actor: user)

      {:ok, lv, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          ConversationView,
          session: %{
            "conversation_id" => conv.id,
            "user_id" => user.id,
            "tab_id" => "tab_ctx_clear"
          }
        )

      # data-confirm does not block render_click in tests.
      lv
      |> Phoenix.LiveViewTest.element(~s([data-role="context-clear"]))
      |> Phoenix.LiveViewTest.render_click()

      {:ok, cw} = Magus.Chat.get_context_window(conv.id, actor: user)
      assert cw.window_start_at != nil
      # The pointer keeps the latest message's id for reference, but the floor is
      # set strictly AFTER it (the history filter is inclusive `>=`), so the
      # latest message is excluded from the next window — Clear empties it.
      assert cw.window_start_message_id == latest.id
      assert DateTime.compare(cw.window_start_at, latest.inserted_at) == :gt

      # The next LLM-context window load excludes the latest message (it is now
      # below the floor), so the window is empty.
      llm_messages = Magus.Chat.build_message_history!(conv.id, nil, false)
      assert llm_messages == []
    end

    test "compact_context marks the persisted window :pending" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Magus.Chat.create_conversation(%{title: "Compact test", workspace_id: ws.id}, actor: user)

      {:ok, lv, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          ConversationView,
          session: %{
            "conversation_id" => conv.id,
            "user_id" => user.id,
            "tab_id" => "tab_ctx_compact"
          }
        )

      lv
      |> Phoenix.LiveViewTest.element(~s([data-role="context-compact"]))
      |> Phoenix.LiveViewTest.render_click()

      {:ok, cw} = Magus.Chat.get_context_window(conv.id, actor: user)
      assert cw.compaction_status == :pending
    end

    test "Send button is disabled while compaction is :running, enabled when :idle" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Magus.Chat.create_conversation(%{title: "Send-lock test", workspace_id: ws.id},
          actor: user
        )

      # Pre-seed a :running context window so the Send button renders disabled
      # on mount (the LiveView reads the persisted snapshot).
      ai_agent = %Magus.Agents.Support.AiAgent{}
      {:ok, cw} = Magus.Chat.get_or_create_context_window(conv.id, actor: ai_agent)
      {:ok, _} = Magus.Chat.mark_context_compacting(cw, %{}, actor: ai_agent)

      session = %{
        "conversation_id" => conv.id,
        "user_id" => user.id,
        "tab_id" => "tab_send_lock"
      }

      {:ok, lv, html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          ConversationView,
          session: session
        )

      assert send_button_disabled?(html)

      # Returning to :idle (via a completed compaction broadcast) re-enables Send.
      {:ok, _} =
        Magus.Chat.compact_context_window(
          cw,
          %{summary: nil, summary_message_count: 0},
          actor: ai_agent
        )

      Magus.Agents.Signals.context_updated(conv.id, %{})
      html2 = Phoenix.LiveViewTest.render(lv)
      refute send_button_disabled?(html2)
    end
  end

  # The send button carries data-role="send-message" and a data-send-disabled
  # flag mirroring its disabled state.
  defp send_button_disabled?(html) do
    html =~ ~s(data-role="send-message") and html =~ ~s(data-send-disabled="true")
  end

  describe "terminate" do
    test "terminate runs without error" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Magus.Chat.create_conversation(
          %{title: "Terminate test", workspace_id: ws.id},
          actor: user
        )

      {:ok, lv, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          MagusWeb.Workbench.Resources.ConversationView,
          session: %{
            "conversation_id" => conv.id,
            "user_id" => user.id,
            "tab_id" => "tab_abc"
          }
        )

      pid = lv.pid
      ref = Process.monitor(pid)

      # Stop the LV
      GenServer.stop(pid, :normal, 2_000)

      # Confirm clean exit
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end
  end

  describe "tool-triggered companion open" do
    test "read_brain tool.complete broadcasts :open_companion for brain_page" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Magus.Chat.create_conversation(%{title: "Brain tool test", workspace_id: ws.id},
          actor: user
        )

      {:ok, brain} =
        Magus.Brain.create_brain(%{title: "Tool brain", workspace_id: ws.id}, actor: user)

      {:ok, page} =
        Magus.Brain.create_page(brain.id, %{title: "Tool page"}, actor: user)

      {:ok, _lv, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          MagusWeb.Workbench.Resources.ConversationView,
          session: %{
            "conversation_id" => conv.id,
            "user_id" => user.id,
            "tab_id" => "tab_brain_tool"
          }
        )

      Phoenix.PubSub.subscribe(
        Magus.PubSub,
        MagusWeb.Workbench.Signals.tab_topic("tab_brain_tool")
      )

      MagusWeb.Endpoint.broadcast(
        "agents:#{conv.id}",
        "agent_signal",
        %{
          type: "tool.complete",
          tool_name: "read_brain",
          event_id: "evt_1",
          result: %{"page_id" => page.id}
        }
      )

      assert_receive {:workbench_companion, {:open, %{"type" => "brain_page", "id" => page_id}}},
                     1_000

      assert page_id == page.id
    end

    test "read_brain tool.complete does NOT open a companion when this chat is itself a companion" do
      # A companion chat is bound to the brain page that is the tab's primary.
      # When its agent navigates/edits that page, opening a brain_page companion
      # would hijack the tab's single companion slot and duplicate the page that
      # is already open as the primary. The companion chat must stay put.
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Magus.Chat.create_conversation(%{title: "Companion brain tool", workspace_id: ws.id},
          actor: user
        )

      {:ok, brain} =
        Magus.Brain.create_brain(%{title: "Companion brain", workspace_id: ws.id}, actor: user)

      {:ok, page} =
        Magus.Brain.create_page(brain.id, %{title: "Companion page"}, actor: user)

      {:ok, _lv, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          MagusWeb.Workbench.Resources.ConversationView,
          session: %{
            "conversation_id" => conv.id,
            "user_id" => user.id,
            "tab_id" => "tab_companion_brain",
            "role" => "companion"
          }
        )

      Phoenix.PubSub.subscribe(
        Magus.PubSub,
        MagusWeb.Workbench.Signals.tab_topic("tab_companion_brain")
      )

      MagusWeb.Endpoint.broadcast(
        "agents:#{conv.id}",
        "agent_signal",
        %{
          type: "tool.complete",
          tool_name: "read_brain",
          event_id: "evt_1",
          result: %{"page_id" => page.id}
        }
      )

      refute_receive {:workbench_companion, {:open, %{"type" => "brain_page"}}}, 300
    end

    test "ui.open_brain_pane does NOT open a companion when this chat is itself a companion" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Magus.Chat.create_conversation(%{title: "Companion brain pane", workspace_id: ws.id},
          actor: user
        )

      {:ok, brain} =
        Magus.Brain.create_brain(%{title: "Pane brain", workspace_id: ws.id}, actor: user)

      {:ok, page} =
        Magus.Brain.create_page(brain.id, %{title: "Pane page"}, actor: user)

      {:ok, _lv, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          MagusWeb.Workbench.Resources.ConversationView,
          session: %{
            "conversation_id" => conv.id,
            "user_id" => user.id,
            "tab_id" => "tab_companion_pane",
            "role" => "companion"
          }
        )

      Phoenix.PubSub.subscribe(
        Magus.PubSub,
        MagusWeb.Workbench.Signals.tab_topic("tab_companion_pane")
      )

      MagusWeb.Endpoint.broadcast(
        "agents:#{conv.id}",
        "agent_signal",
        %{type: "ui.open_brain_pane", page_id: page.id}
      )

      refute_receive {:workbench_companion, {:open, %{"type" => "brain_page"}}}, 300
    end

    test "draft.created PubSub broadcasts :open_companion for draft" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Magus.Chat.create_conversation(%{title: "Tool open", workspace_id: ws.id}, actor: user)

      {:ok, lv, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          ConversationView,
          session: %{
            "conversation_id" => conv.id,
            "user_id" => user.id,
            "tab_id" => "tab_tool_test"
          }
        )

      # Subscribe to the tab topic so we can observe the companion broadcast
      Phoenix.PubSub.subscribe(
        Magus.PubSub,
        MagusWeb.Workbench.Signals.tab_topic("tab_tool_test")
      )

      # Creating a draft fires `draft.created` via BroadcastDraftEvent. The
      # `tool.complete` payload from ToolEventPlugin does not carry the result
      # map, so the auto-open is wired to the dedicated draft topic instead.
      {:ok, draft} =
        Magus.Drafts.create_draft(conv.id, "Tool-written", "content", user.id, actor: user)

      assert_receive {:workbench_companion, {:open, %{"type" => "draft", "id" => draft_id}}},
                     1_000

      assert draft_id == draft.id
      _ = lv
    end
  end

  describe "agent streaming" do
    test "renders a text.chunk delta into a streaming message" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Magus.Chat.create_conversation(
          %{title: "Streaming test", workspace_id: ws.id},
          actor: user
        )

      # Use a synthetic UUID for the in-flight streaming message
      agent_msg_id = Ash.UUID.generate()

      {:ok, lv, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          ConversationView,
          session: %{
            "conversation_id" => conv.id,
            "user_id" => user.id,
            "tab_id" => "tab_abc"
          }
        )

      # Use MagusWeb.Endpoint.broadcast to match how Magus.Agents.Signals
      # actually delivers events in production (wraps in Phoenix.Socket.Broadcast).
      MagusWeb.Endpoint.broadcast(
        "agents:#{conv.id}",
        "agent_signal",
        %{
          type: "text.chunk",
          message_id: agent_msg_id,
          text: "partial response",
          delta: "partial response"
        }
      )

      :ok = poll_until(fn -> Phoenix.LiveViewTest.render(lv) =~ "partial response" end)
    end

    test "state.change updates thinking_status and waiting_for_response" do
      # state.change is one of the agent signals that the workbench previously
      # never reacted to (no per-type handle_info clause). The canonical
      # PubSubHandlers dispatcher now drives this — confirm it propagates to
      # assigns end-to-end.
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Magus.Chat.create_conversation(
          %{title: "State change test", workspace_id: ws.id},
          actor: user
        )

      {:ok, lv, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          ConversationView,
          session: %{
            "conversation_id" => conv.id,
            "user_id" => user.id,
            "tab_id" => "tab_state"
          }
        )

      MagusWeb.Endpoint.broadcast(
        "agents:#{conv.id}",
        "agent_signal",
        %{type: "state.change", state: :streaming}
      )

      :ok =
        poll_until(fn ->
          assigns = :sys.get_state(lv.pid).socket.assigns
          assigns.is_streaming == true
        end)
    end
  end

  describe "model and chat mode persistence" do
    test "model_selected notification persists to conversation record" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Magus.Chat.create_conversation(%{title: "Persist model", workspace_id: ws.id},
          actor: user
        )

      {:ok, lv, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          ConversationView,
          session: %{
            "conversation_id" => conv.id,
            "user_id" => user.id,
            "tab_id" => "tab_model_persist"
          }
        )

      new_model = generate(model())

      send(
        lv.pid,
        {MagusWeb.ChatLive.Components.ChatInput.ModelSelectorComponent,
         {:model_selected, new_model.id, :chat, %{}}}
      )

      :ok =
        poll_until(fn ->
          case Magus.Chat.get_conversation(conv.id, actor: user) do
            {:ok, reloaded} -> reloaded.selected_model_id == new_model.id
            _ -> false
          end
        end)
    end

    test "mode_changed notification persists chat_mode to conversation record" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Magus.Chat.create_conversation(%{title: "Persist mode", workspace_id: ws.id}, actor: user)

      {:ok, lv, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          ConversationView,
          session: %{
            "conversation_id" => conv.id,
            "user_id" => user.id,
            "tab_id" => "tab_mode_persist"
          }
        )

      send(
        lv.pid,
        {MagusWeb.ChatLive.Components.ChatInput.ModelSelectorComponent,
         {:mode_changed, :reasoning, nil, %{}}}
      )

      :ok =
        poll_until(fn ->
          case Magus.Chat.get_conversation(conv.id, actor: user) do
            {:ok, reloaded} -> reloaded.chat_mode == :reasoning
            _ -> false
          end
        end)
    end
  end
end
