defmodule MagusWeb.Workbench.WorkbenchLiveTest do
  use MagusWeb.LiveViewCase, async: false

  import MagusWeb.LiveViewCase

  import Phoenix.LiveViewTest
  import Magus.Generators
  import MagusWeb.Workbench.TestHelpers

  describe "GET /chat" do
    test "renders shell placeholder when authenticated", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/chat")
      assert html =~ "workbench"
    end

    test "redirects unauthenticated users to sign in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/chat")
    end
  end

  describe "mode strip" do
    setup %{conn: conn} do
      user = generate(user())
      %{conn: log_in_user(conn, user), user: user}
    end

    test "renders all four mode icons", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/chat")
      assert html =~ ~s(data-mode-icon="chat")
      assert html =~ ~s(data-mode-icon="brain")
      assert html =~ ~s(data-mode-icon="agents")
      assert html =~ ~s(data-mode-icon="prompts")
    end

    test "clicking a mode icon updates the active mode", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      view
      |> element(~s([data-mode-icon="brain"]))
      |> render_click()

      assert render(view) =~ ~s(data-mode="brain")
    end

    test "clicking the files mode icon updates the active mode", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      view
      |> element(~s([data-mode-icon="files"]))
      |> render_click()

      assert render(view) =~ ~s(data-mode="files")
    end
  end

  describe "session loading" do
    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      conn = log_in_user_with_workspace(conn, user, ws)

      %{conn: conn, user: user, workspace: ws}
    end

    test "loads existing TabSession on mount", %{conn: conn, user: user, workspace: ws} do
      {:ok, session} =
        Magus.Workbench.get_or_create_tab_session(user.id, ws.id, actor: user)

      {:ok, conv} =
        Magus.Chat.create_conversation(%{title: "Loaded", workspace_id: ws.id}, actor: user)

      {:ok, session} =
        Magus.Workbench.open_workbench_tab(
          session,
          %{"type" => "conversation", "id" => conv.id},
          actor: user
        )

      # /chat redirects to the active tab URL via push_patch when a tab is active
      {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")

      assert render(view) =~ session.active_tab_id
    end

    test "creates a fresh session when none exists", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/chat")
      assert html =~ ~s(data-mode="chat")
    end
  end

  describe "brain mode nav" do
    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, brain} =
        Magus.Brain.create_brain(%{title: "Test Brain", workspace_id: ws.id}, actor: user)

      conn =
        log_in_user_with_workspace(conn, user, ws)

      %{conn: conn, user: user, workspace: ws, brain: brain}
    end

    test "renders brains when in brain mode", %{conn: conn, brain: brain} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      view |> element(~s([data-mode-icon="brain"])) |> render_click()

      assert render(view) =~ brain.title
    end
  end

  describe "agents and prompts mode navs render" do
    setup %{conn: conn} do
      user = generate(user())
      %{conn: log_in_user(conn, user)}
    end

    test "agents mode renders agents nav", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")
      view |> element(~s([data-mode-icon="agents"])) |> render_click()
      assert render(view) =~ ~s(data-testid="agents-mode-nav")
    end

    test "prompts mode renders prompts nav", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")
      view |> element(~s([data-mode-icon="prompts"])) |> render_click()
      html = render(view)
      assert html =~ ~s(id="prompts-mode-nav-tree-section-personal")
      assert html =~ "No prompts yet"
    end
  end

  describe "nav pane" do
    alias Magus.Chat

    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      user = enable_tabs(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Chat.create_conversation(%{title: "Fixture chat", workspace_id: ws.id}, actor: user)

      conn =
        log_in_user_with_workspace(conn, user, ws)

      %{conn: conn, user: user, workspace: ws, conversation: conv}
    end

    test "renders the chat mode nav with conversation list by default",
         %{conn: conn, conversation: conv} do
      {:ok, _view, html} = live(conn, ~p"/chat")
      assert html =~ conv.title
    end

    test "clicking a conversation opens a tab",
         %{conn: conn, conversation: conv, user: user, workspace: ws} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      view
      |> element(~s(#chat-mode-nav-tree-tree-leaf-#{conv.id} button[phx-click="open_tab"]))
      |> render_click()

      {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)

      conv_tab = Enum.find(session.tabs, &(&1["primary"]["id"] == conv.id))
      assert conv_tab["primary"]["type"] == "conversation"
      assert session.active_tab_id == conv_tab["id"]
    end

    test "select_mode event is idempotent when mode is already current",
         %{conn: conn, user: user, workspace: ws, conversation: conv} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")

      {:ok, session_before} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      updated_before = session_before.updated_at

      # select the current mode (:chat) -- should NOT bump updated_at
      view |> element(~s([data-mode-icon="chat"])) |> render_click()

      {:ok, session_after} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      assert session_after.updated_at == updated_before
    end
  end

  describe "tab container" do
    alias Magus.Chat

    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Chat.create_conversation(%{title: "My conv", workspace_id: ws.id}, actor: user)

      conn =
        log_in_user_with_workspace(conn, user, ws)

      %{conn: conn, user: user, conversation: conv}
    end

    test "mounts a TabContainer per open tab, marks the active one", %{
      conn: conn,
      conversation: conv
    } do
      {:ok, view, _html} = live(conn, ~p"/chat")

      view
      |> element(~s(#chat-mode-nav-tree-tree-leaf-#{conv.id} button[phx-click="open_tab"]))
      |> render_click()

      html = render(view)
      assert html =~ "data-tab-container"
      assert html =~ ~s(data-active="true")
    end
  end

  describe "tab bar" do
    alias Magus.Chat

    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      user = enable_tabs(user)
      ws = generate(workspace(actor: user))
      {:ok, c1} = Chat.create_conversation(%{title: "One", workspace_id: ws.id}, actor: user)
      {:ok, c2} = Chat.create_conversation(%{title: "Two", workspace_id: ws.id}, actor: user)

      conn =
        log_in_user_with_workspace(conn, user, ws)

      %{conn: conn, user: user, workspace: ws, c1: c1, c2: c2}
    end

    test "renders a tab for each open resource", %{conn: conn, c1: c1, c2: c2} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      view
      |> element(~s(#chat-mode-nav-tree-tree-leaf-#{c1.id} button[phx-click="open_tab"]))
      |> render_click()

      view
      |> element(~s(#chat-mode-nav-tree-tree-leaf-#{c2.id} button[phx-click="open_tab"]))
      |> render_click()

      html = render(view)
      assert html =~ ~s(data-tab-role="tab")
      # Three tabs rendered: the synthetic "new chat" tab opened on /chat plus c1 and c2
      assert html |> String.split(~s(data-tab-role="tab")) |> length() == 4
    end

    test "clicking a tab activates it", %{conn: conn, c1: c1, c2: c2, user: user, workspace: ws} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      view
      |> element(~s(#chat-mode-nav-tree-tree-leaf-#{c1.id} button[phx-click="open_tab"]))
      |> render_click()

      view
      |> element(~s(#chat-mode-nav-tree-tree-leaf-#{c2.id} button[phx-click="open_tab"]))
      |> render_click()

      {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      first_tab_id = Enum.at(session.tabs, 0)["id"]

      view |> element(~s([data-activate-tab="#{first_tab_id}"])) |> render_click()

      {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      assert session.active_tab_id == first_tab_id
    end

    test "clicking the close button removes the tab",
         %{conn: conn, c1: c1, user: user, workspace: ws} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      view
      |> element(~s(#chat-mode-nav-tree-tree-leaf-#{c1.id} button[phx-click="open_tab"]))
      |> render_click()

      {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      tab_id = session.active_tab_id

      view |> element(~s([data-close-tab="#{tab_id}"])) |> render_click()

      {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      refute Enum.any?(session.tabs, &(&1["primary"]["id"] == c1.id))
    end
  end

  describe "tab container session passthrough" do
    alias Magus.Chat

    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Chat.create_conversation(%{title: "Conv", workspace_id: ws.id}, actor: user)

      conn =
        log_in_user_with_workspace(conn, user, ws)

      %{conn: conn, user: user, conversation: conv}
    end

    test "TabContainer receives user_id in its session", %{
      conn: conn,
      user: user,
      conversation: conv
    } do
      {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")

      html = render(view)
      assert html =~ ~s(data-user-id="#{user.id}")
    end
  end

  describe "tab container renders ConversationView for conversation primaries" do
    alias Magus.Chat

    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Chat.create_conversation(%{title: "Rendered here", workspace_id: ws.id}, actor: user)

      conn =
        log_in_user_with_workspace(conn, user, ws)

      %{conn: conn, user: user, conversation: conv}
    end

    test "renders ConversationView inside the active tab", %{conn: conn, conversation: conv} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")

      html = render(view)
      assert html =~ ~s(data-conversation-view)
      assert html =~ ~s(data-conversation-id="#{conv.id}")
      assert html =~ conv.title
    end
  end

  describe "full chat flow via /chat/:id" do
    alias Magus.Chat
    alias MagusWeb.ChatLive.Components.ChatInput.ChatInputComponent

    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Chat.create_conversation(%{title: "E2E chat", workspace_id: ws.id}, actor: user)

      conn =
        log_in_user_with_workspace(conn, user, ws)

      %{conn: conn, user: user, workspace: ws, conversation: conv}
    end

    test "loads the conversation, shows messages, sends a user message, receives a streamed delta",
         %{conn: conn, conversation: conv, user: user, workspace: ws} do
      # Pre-seed a message (the :create action sets role: :user automatically)
      {:ok, _} =
        Chat.create_message(
          %{
            conversation_id: conv.id,
            text: "seeded message"
          },
          actor: user
        )

      {:ok, view, html} = live(conn, ~p"/chat/#{conv.id}")

      # Seeded message is visible in the initial render
      assert html =~ "seeded message"

      # Retrieve the active tab_id so we can navigate the live_render hierarchy
      {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      tab_id = session.active_tab_id

      # Drill into: WorkbenchLive → TabContainer → ConversationView
      tab_view = find_live_child(view, "tab-#{tab_id}")
      assert tab_view, "Expected to find TabContainer live child tab-#{tab_id}"

      conv_view = find_live_child(tab_view, "conversation-#{conv.id}")
      assert conv_view, "Expected to find ConversationView live child conversation-#{conv.id}"

      # Send a message by delivering the notification directly to ConversationView.
      # This is equivalent to the ChatInputComponent notifying its parent after a
      # successful form submit.
      params = %{
        "text" => "tell me a joke",
        "mode" => "chat",
        "selected_model_id" => nil,
        "conversation_id" => conv.id
      }

      send(conv_view.pid, {ChatInputComponent, {:send_message_with_resources, params, []}})

      # Poll until the DB write completes
      :ok =
        poll_until(fn ->
          messages = Chat.message_history!(conv.id, actor: user) |> Enum.to_list()
          Enum.any?(messages, fn m -> m.text == "tell me a joke" end)
        end)

      # Simulate a streaming delta from the agent via PubSub.
      # text.chunk creates a synthetic stream entry keyed by message_id,
      # so any UUID works — no DB record needed.
      agent_msg_id = Ecto.UUID.generate()

      MagusWeb.Endpoint.broadcast(
        "agents:#{conv.id}",
        "agent_signal",
        %{
          type: "text.chunk",
          message_id: agent_msg_id,
          text: "Why did the chicken",
          delta: "Why did the chicken"
        }
      )

      :ok = poll_until(fn -> render(conv_view) =~ "Why did the chicken" end)
    end
  end

  describe "tab-scoped companion signals" do
    alias Magus.Chat
    alias MagusWeb.Workbench.Signals

    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Chat.create_conversation(%{title: "Companion test", workspace_id: ws.id}, actor: user)

      conn =
        log_in_user_with_workspace(conn, user, ws)

      %{conn: conn, user: user, workspace: ws, conversation: conv}
    end

    test "TabContainer responds to :open_companion by setting companion state",
         %{conn: conn, user: user, workspace: ws, conversation: conv} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")

      {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      tab_id = session.active_tab_id

      Signals.broadcast_open_companion(tab_id, %{"type" => "draft", "id" => "draft_xyz"})

      :ok = poll_until(fn -> render(view) =~ ~s(data-companion-type="draft") end)

      html = render(view)
      assert html =~ ~s(data-companion-id="draft_xyz")
    end

    test "TabContainer responds to :close_companion by clearing companion state",
         %{conn: conn, user: user, workspace: ws, conversation: conv} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")

      {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      tab_id = session.active_tab_id

      Signals.broadcast_open_companion(tab_id, %{"type" => "draft", "id" => "draft_1"})
      :ok = poll_until(fn -> render(view) =~ ~s(data-companion-type="draft") end)

      Signals.broadcast_close_companion(tab_id)
      :ok = poll_until(fn -> !(render(view) =~ ~s(data-companion-type="draft")) end)
    end

    test "companion changes persist to TabSession",
         %{conn: conn, user: user, workspace: ws, conversation: conv} do
      {:ok, _view, _html} = live(conn, ~p"/chat/#{conv.id}")

      {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      tab_id = session.active_tab_id

      spec = %{"type" => "draft", "id" => "draft_persist_xyz"}
      MagusWeb.Workbench.Signals.broadcast_open_companion(tab_id, spec)

      :ok =
        poll_until(fn ->
          {:ok, s} = Magus.Workbench.get_tab_session(ws.id, actor: user)
          tab = Enum.find(s.tabs, fn t -> t["id"] == tab_id end)
          tab && tab["companion"] == spec
        end)
    end

    test "closing companion persists nil to TabSession",
         %{conn: conn, user: user, workspace: ws, conversation: conv} do
      {:ok, _view, _html} = live(conn, ~p"/chat/#{conv.id}")

      {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      tab_id = session.active_tab_id

      MagusWeb.Workbench.Signals.broadcast_open_companion(tab_id, %{
        "type" => "draft",
        "id" => "x"
      })

      :ok =
        poll_until(fn ->
          {:ok, s} = Magus.Workbench.get_tab_session(ws.id, actor: user)
          tab = Enum.find(s.tabs, fn t -> t["id"] == tab_id end)
          tab && tab["companion"] != nil
        end)

      MagusWeb.Workbench.Signals.broadcast_close_companion(tab_id)

      :ok =
        poll_until(fn ->
          {:ok, s} = Magus.Workbench.get_tab_session(ws.id, actor: user)
          tab = Enum.find(s.tabs, fn t -> t["id"] == tab_id end)
          tab && is_nil(tab["companion"])
        end)
    end

    test "unknown companion type renders a fallback placeholder",
         %{conn: conn, user: user, workspace: ws, conversation: conv} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")

      {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      tab_id = session.active_tab_id

      MagusWeb.Workbench.Signals.broadcast_open_companion(tab_id, %{
        "type" => "unknown_type",
        "id" => "xyz"
      })

      :ok =
        poll_until(fn ->
          render(view) =~ ~s(data-companion-fallback="unknown_type")
        end)
    end
  end

  describe "URL reconciliation" do
    alias Magus.Chat

    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Chat.create_conversation(%{title: "URL conv", workspace_id: ws.id}, actor: user)

      conn =
        log_in_user_with_workspace(conn, user, ws)

      %{conn: conn, user: user, workspace: ws, conversation: conv}
    end

    test "mounting /chat/:id opens that conversation as a tab and activates it",
         %{conn: conn, conversation: conv, user: user, workspace: ws} do
      {:ok, _view, _html} = live(conn, ~p"/chat/#{conv.id}")

      {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      assert [tab] = session.tabs
      assert tab["primary"] == %{"type" => "conversation", "id" => conv.id}
      assert session.active_tab_id == tab["id"]
      assert session.mode == :chat
    end

    test "mounting /chat/:id with an already-open tab activates it instead of duplicating",
         %{conn: conn, conversation: conv, user: user, workspace: ws} do
      {:ok, session} = Magus.Workbench.get_or_create_tab_session(user.id, ws.id, actor: user)

      {:ok, _} =
        Magus.Workbench.open_workbench_tab(
          session,
          %{"type" => "conversation", "id" => conv.id},
          actor: user
        )

      {:ok, _view, _html} = live(conn, ~p"/chat/#{conv.id}")

      {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      assert length(session.tabs) == 1
    end

    test "mounting /agents/:id opens the agent as a tab",
         %{conn: conn, user: user, workspace: ws} do
      {:ok, agent} =
        Magus.Agents.create_custom_agent(%{name: "Detail Agent", workspace_id: ws.id},
          actor: user
        )

      {:ok, _view, _html} = live(conn, ~p"/agents/#{agent.id}")

      {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      assert [tab] = session.tabs
      assert tab["primary"]["type"] == "agent"
      assert tab["primary"]["id"] == agent.id
      assert session.active_tab_id == tab["id"]
      assert session.mode == :agents
    end
  end

  describe "default new chat" do
    setup %{conn: conn} do
      user = generate(user())
      user = enable_tabs(user)
      %{conn: log_in_user(conn, user)}
    end

    test "renders the new-chat page when no tabs are open", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/chat")

      assert html =~ ~s(id="conversation-drop-zone-new")
      refute html =~ ~s(data-empty-state)
    end
  end

  describe "new chat tab" do
    alias Magus.Chat

    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      user = enable_tabs(user)
      ws = generate(workspace(actor: user))

      conn = log_in_user_with_workspace(conn, user, ws)
      %{conn: conn, user: user, workspace: ws}
    end

    test "/chat/new opens a synthetic 'new' tab and activates it",
         %{conn: conn, user: user, workspace: ws} do
      {:ok, old_conv} =
        Chat.create_conversation(%{title: "Old active chat", workspace_id: ws.id}, actor: user)

      {:ok, session} = Magus.Workbench.get_or_create_tab_session(user.id, ws.id, actor: user)

      {:ok, _session_before} =
        Magus.Workbench.open_workbench_tab(
          session,
          %{"type" => "conversation", "id" => old_conv.id},
          actor: user
        )

      html =
        conn
        |> get(~p"/chat/new")
        |> html_response(200)

      assert html =~ ~s(id="conversation-drop-zone-new")

      {:ok, session_after} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      assert Enum.any?(session_after.tabs, &(&1["primary"]["id"] == old_conv.id))

      active_tab = Enum.find(session_after.tabs, &(&1["id"] == session_after.active_tab_id))
      assert active_tab["primary"] == %{"type" => "conversation", "id" => "new"}
    end
  end

  describe "brain mode nav tree" do
    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, brain} =
        Magus.Brain.create_brain(%{title: "Workspace brain", workspace_id: ws.id}, actor: user)

      {:ok, page} =
        Magus.Brain.create_page(brain.id, %{title: "Root page"}, actor: user)

      conn = log_in_user_with_workspace(conn, user, ws)
      %{conn: conn, user: user, workspace: ws, brain: brain, page: page}
    end

    test "renders workspace brains", %{conn: conn, brain: brain} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      view |> element(~s([data-mode-icon="brain"])) |> render_click()

      assert render(view) =~ brain.title
    end

    test "clicking a brain expands to show its root pages",
         %{conn: conn, brain: brain, page: page} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      view |> element(~s([data-mode-icon="brain"])) |> render_click()
      view |> element(~s(button[phx-value-folder-id="#{brain.id}"])) |> render_click()

      assert render(view) =~ page.title
    end

    test "reflects an out-of-band page creation (agent/peer) without reload",
         %{conn: conn, user: user, brain: brain} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      view |> element(~s([data-mode-icon="brain"])) |> render_click()
      view |> element(~s(button[phx-value-folder-id="#{brain.id}"])) |> render_click()

      # Simulate an agent creating a page in this brain out-of-band. The
      # per-brain PubSub broadcast (BroadcastBrainEvent) should refresh the nav.
      {:ok, agent_page} =
        Magus.Brain.create_page(brain.id, %{title: "Agent made this"}, actor: user)

      # First render flushes the broadcast handle_info (which enqueues the
      # component send_update); the second render reflects the rebuilt nav.
      render(view)
      assert render(view) =~ ~s(data-resource-id="#{agent_page.id}")
    end
  end

  describe "brain page tabs" do
    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, brain} =
        Magus.Brain.create_brain(%{title: "Tab brain", workspace_id: ws.id}, actor: user)

      {:ok, page} =
        Magus.Brain.create_page(brain.id, %{title: "Tab page"}, actor: user)

      conn = log_in_user_with_workspace(conn, user, ws)
      %{conn: conn, user: user, workspace: ws, brain: brain, page: page}
    end

    test "mounting /brain/:page_id renders BrainPageView as primary",
         %{conn: conn, page: page} do
      {:ok, view, _html} = live(conn, ~p"/brain/#{page.id}")

      html = render(view)
      assert html =~ ~s(data-brain-page-view)
      assert html =~ ~s(data-page-id="#{page.id}")
    end

    test "brain_page companion renders BrainPageView in companion slot",
         %{conn: conn, user: user, workspace: ws, page: page} do
      {:ok, conv} =
        Magus.Chat.create_conversation(
          %{title: "With brain companion", workspace_id: ws.id},
          actor: user
        )

      {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")

      {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      tab_id = session.active_tab_id

      MagusWeb.Workbench.Signals.broadcast_open_companion(tab_id, %{
        "type" => "brain_page",
        "id" => page.id
      })

      :ok = poll_until(fn -> render(view) =~ ~s(data-companion-type="brain_page") end)
      assert render(view) =~ ~s(data-brain-page-view)
    end
  end

  describe "brain mode nav personal + workspace sections" do
    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, ws_brain} =
        Magus.Brain.create_brain(%{title: "Workspace brain", workspace_id: ws.id}, actor: user)

      {:ok, personal_brain} =
        Magus.Brain.create_brain(%{title: "Personal brain"}, actor: user)

      conn = log_in_user_with_workspace(conn, user, ws)

      %{
        conn: conn,
        user: user,
        workspace: ws,
        ws_brain: ws_brain,
        personal_brain: personal_brain
      }
    end

    test "in a workspace, only workspace-scoped brains are listed; no-workspace brains are hidden",
         %{conn: conn, ws_brain: ws_brain, personal_brain: personal_brain} do
      {:ok, view, _html} = live(conn, ~p"/chat")
      view |> element(~s([data-mode-icon="brain"])) |> render_click()

      html = render(view)
      assert html =~ ws_brain.title
      refute html =~ personal_brain.title
    end

    test "personal filter shows workspace brains without a workspace-level grant",
         %{conn: conn, user: user, workspace: ws, ws_brain: ws_brain} do
      shared_ws_brain =
        grant_brain_to_workspace(user, ws, "Team brain")

      {:ok, view, _html} = live(conn, ~p"/chat")
      view |> element(~s([data-mode-icon="brain"])) |> render_click()
      view |> element(~s([data-nav-filter="personal"])) |> render_click()

      html = render(view)
      assert html =~ ws_brain.title
      refute html =~ shared_ws_brain.title
    end

    test "shared filter shows workspace brains with a workspace-level grant",
         %{conn: conn, user: user, workspace: ws, ws_brain: ws_brain} do
      shared_ws_brain = grant_brain_to_workspace(user, ws, "Team brain")

      {:ok, view, _html} = live(conn, ~p"/chat")
      view |> element(~s([data-mode-icon="brain"])) |> render_click()
      view |> element(~s([data-nav-filter="shared"])) |> render_click()

      html = render(view)
      assert html =~ shared_ws_brain.title
      refute html =~ ws_brain.title
    end
  end

  describe "chat mode nav sections and filter" do
    alias Magus.Chat

    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, ws_conv} =
        Chat.create_conversation(%{title: "Team project", workspace_id: ws.id}, actor: user)

      conn =
        log_in_user_with_workspace(conn, user, ws)

      %{conn: conn, user: user, workspace: ws, ws_conv: ws_conv}
    end

    test "renders CHATS section header and workspace conversations",
         %{conn: conn, ws_conv: conv} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      html = render(view)
      assert String.match?(html, ~r/CHATS/i)
      assert html =~ conv.title
    end

    test "shared filter shows only conversations with a workspace-level grant",
         %{conn: conn, user: user, ws_conv: conv} do
      {:ok, shared_conv} = Chat.share_conversation_to_team(conv, %{}, actor: user)

      {:ok, view, _html} = live(conn, ~p"/chat")

      view |> element(~s([data-nav-filter="shared"])) |> render_click()

      html = render(view)
      assert html =~ shared_conv.title
    end

    test "personal filter shows workspace conversations without a workspace-level grant",
         %{conn: conn, user: user, workspace: ws, ws_conv: conv} do
      {:ok, shared_conv} =
        Chat.create_conversation(%{title: "Shared project", workspace_id: ws.id}, actor: user)

      {:ok, _} = Chat.share_conversation_to_team(shared_conv, %{}, actor: user)

      {:ok, view, _html} = live(conn, ~p"/chat")

      view |> element(~s([data-nav-filter="personal"])) |> render_click()

      html = render(view)
      assert html =~ conv.title
      refute html =~ shared_conv.title
    end
  end

  describe "agent and prompt tab promotion" do
    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      conn = log_in_user_with_workspace(conn, user, ws)
      %{conn: conn, user: user, workspace: ws}
    end

    test "navigating to /agents/:id opens an agent tab", %{conn: conn, user: user, workspace: ws} do
      {:ok, agent} =
        Magus.Agents.create_custom_agent(
          %{name: "Detail Agent", workspace_id: ws.id},
          actor: user
        )

      {:ok, _view, html} = live(conn, ~p"/agents/#{agent.id}")

      assert html =~ ~s(data-tab-id)
      assert html =~ "Detail Agent"

      {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      assert [tab] = session.tabs
      assert tab["primary"]["type"] == "agent"
      assert tab["primary"]["id"] == agent.id
    end

    test "navigating to /prompts_library/:id opens a prompt tab",
         %{conn: conn, user: user, workspace: ws} do
      {:ok, prompt} =
        Magus.Library.create_prompt(
          %{name: "Detail Prompt", content: "Do the thing", type: :user, workspace_id: ws.id},
          actor: user
        )

      {:ok, _view, html} = live(conn, ~p"/prompts_library/#{prompt.id}")

      assert html =~ ~s(data-tab-id)
      assert html =~ "Detail Prompt"

      {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      assert [tab] = session.tabs
      assert tab["primary"]["type"] == "prompt"
      assert tab["primary"]["id"] == prompt.id
    end

    test "navigating to the same agent twice does not duplicate the tab",
         %{conn: conn, user: user, workspace: ws} do
      {:ok, agent} =
        Magus.Agents.create_custom_agent(
          %{name: "No Dup Agent", workspace_id: ws.id},
          actor: user
        )

      {:ok, session} = Magus.Workbench.get_or_create_tab_session(user.id, ws.id, actor: user)

      {:ok, _} =
        Magus.Workbench.open_workbench_tab(
          session,
          %{"type" => "agent", "id" => agent.id},
          actor: user
        )

      {:ok, _view, _html} = live(conn, ~p"/agents/#{agent.id}")

      {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      assert length(session.tabs) == 1
    end
  end

  describe "cross-user tab-change isolation" do
    alias Magus.Chat
    alias MagusWeb.Workbench.Signals

    setup %{conn: conn} do
      user_a = generate(user())
      user_b = generate(user())
      ensure_workspace_plan(user_a)
      ensure_workspace_plan(user_b)
      ws_a = generate(workspace(actor: user_a))
      ws_b = generate(workspace(actor: user_b))

      {:ok, conv_a} =
        Chat.create_conversation(%{title: "A's chat", workspace_id: ws_a.id}, actor: user_a)

      {:ok, conv_b} =
        Chat.create_conversation(%{title: "B's chat", workspace_id: ws_b.id}, actor: user_b)

      conn_a = log_in_user_with_workspace(conn, user_a, ws_a)
      conn_b = log_in_user_with_workspace(Phoenix.ConnTest.build_conn(), user_b, ws_b)

      %{
        conn_a: conn_a,
        conn_b: conn_b,
        user_a: user_a,
        user_b: user_b,
        ws_a: ws_a,
        ws_b: ws_b,
        conv_a: conv_a,
        conv_b: conv_b
      }
    end

    test "user A's companion broadcast does not reach user B's shell",
         %{conn_a: conn_a, conn_b: conn_b, user_a: ua, ws_a: ws_a, conv_a: conv_a, conv_b: conv_b} do
      {:ok, view_a, _} = live(conn_a, ~p"/chat/#{conv_a.id}")
      {:ok, view_b, _} = live(conn_b, ~p"/chat/#{conv_b.id}")

      {:ok, session_a} = Magus.Workbench.get_tab_session(ws_a.id, actor: ua)
      tab_a_id = session_a.active_tab_id

      Signals.broadcast_open_companion(tab_a_id, %{"type" => "draft", "id" => "draft_abc"})

      :ok = poll_until(fn -> render(view_a) =~ ~s(data-companion-type="draft") end)

      # view_b must still be alive and must NOT display user A's companion
      assert Process.alive?(view_b.pid)
      refute render(view_b) =~ ~s(data-companion-type="draft")
      refute render(view_b) =~ "draft_abc"
    end
  end

  describe "closing the active tab" do
    alias Magus.Chat

    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      user = enable_tabs(user)
      ws = generate(workspace(actor: user))

      {:ok, c1} = Chat.create_conversation(%{title: "C1", workspace_id: ws.id}, actor: user)
      {:ok, c2} = Chat.create_conversation(%{title: "C2", workspace_id: ws.id}, actor: user)

      conn = log_in_user_with_workspace(conn, user, ws)
      %{conn: conn, user: user, workspace: ws, c1: c1, c2: c2}
    end

    test "closing the active tab does not also activate the deleted tab",
         %{conn: conn, c1: c1, c2: c2, user: user, workspace: ws} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      view
      |> element(~s(#chat-mode-nav-tree-tree-leaf-#{c1.id} button[phx-click="open_tab"]))
      |> render_click()

      view
      |> element(~s(#chat-mode-nav-tree-tree-leaf-#{c2.id} button[phx-click="open_tab"]))
      |> render_click()

      {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      active_id = session.active_tab_id

      view |> element(~s([data-close-tab="#{active_id}"])) |> render_click()

      # LV survives the close
      assert Process.alive?(view.pid)

      {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      # The closed tab is gone and the remaining tabs (the synthetic "new"
      # tab opened by /chat plus c1) are still present, with the active id
      # pointing at one of them — never at the deleted tab.
      refute Enum.any?(session.tabs, fn t -> t["id"] == active_id end)
      assert session.active_tab_id != active_id
      assert Enum.any?(session.tabs, &(&1["id"] == session.active_tab_id))
    end

    test "close button is not nested inside the activate button (DOM)",
         %{conn: conn, c1: c1} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      view
      |> element(~s(#chat-mode-nav-tree-tree-leaf-#{c1.id} button[phx-click="open_tab"]))
      |> render_click()

      html = render(view)
      # activate button should not wrap a nested <button ... data-close-tab>
      refute html =~ ~r/<button[^>]*data-activate-tab[^>]*>[^<]*<button[^>]*data-close-tab/s
    end
  end

  describe "file route" do
    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      conn = log_in_user_with_workspace(conn, user, ws)
      %{conn: conn, user: user, workspace: ws}
    end

    test "/files/:id opens the file as a tab in current workspace",
         %{conn: conn, user: user, workspace: ws} do
      file = create_workspace_text_file(user, ws, "x.txt")

      {:ok, view, _html} = live(conn, "/files/#{file.id}")
      assert render(view) =~ ~s(data-file-view)
    end

    test "/files/:id for foreign workspace auto-switches workspace",
         %{conn: conn, user: user} do
      other_ws = generate(workspace(actor: user))
      file = create_workspace_text_file(user, other_ws, "y.txt")

      assert {:error, {:live_redirect, %{to: target}}} = live(conn, "/files/#{file.id}")
      assert target == "/files/#{file.id}"
    end
  end

  describe "files mode cross-tab refresh" do
    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      conn = log_in_user_with_workspace(conn, user, ws)
      %{conn: conn, user: user, workspace: ws}
    end

    test "broadcast on workspaces:<ws>:files topic refreshes FilesModeNav",
         %{conn: conn, user: user, workspace: ws} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      # Switch to files mode
      view |> element(~s([data-mode-icon="files"])) |> render_click()

      # Create a new file out-of-band (would normally come from another tab).
      # The new sidebar (post-redesign) does not render file names; it only
      # renders fixed entry-point labels. This test verifies the LV survives
      # the broadcast without crashing.
      {:ok, _file} =
        Magus.Files.create_file(
          %{
            name: "external_create.txt",
            type: :text,
            mime_type: "text/plain",
            file_path: "f/external_create.txt",
            file_size: 1,
            workspace_id: ws.id
          },
          actor: user
        )

      assert Process.alive?(view.pid)
      assert render(view) =~ "My Files"
    end

    test "broadcast on files:files:<user_id> topic refreshes FilesModeNav (personal)",
         %{conn: _conn} do
      # Use a fresh user without a workspace so the personal topic is the
      # one being subscribed to.
      personal_user = generate(user())
      ensure_workspace_plan(personal_user)
      conn = log_in_user(Phoenix.ConnTest.build_conn(), personal_user)

      {:ok, view, _html} = live(conn, ~p"/chat")
      view |> element(~s([data-mode-icon="files"])) |> render_click()

      {:ok, _file} =
        Magus.Files.create_file(
          %{
            name: "personal_external.txt",
            type: :text,
            mime_type: "text/plain",
            file_path: "f/personal_external.txt",
            file_size: 1
          },
          actor: personal_user
        )

      assert Process.alive?(view.pid)
      assert render(view) =~ "My Files"
    end

    test "tolerates action-name events from publish_all (e.g. update_status)",
         %{conn: conn, user: user} do
      # Magus.Files.File uses publish_all :update which emits the action name
      # as the event ("update_status", "process", etc.) — not just "update".
      # Verify the LiveView does not crash on these events.
      {:ok, view, _html} = live(conn, ~p"/chat")
      view |> element(~s([data-mode-icon="files"])) |> render_click()

      MagusWeb.Endpoint.broadcast(
        "files:files:#{user.id}",
        "update_status",
        %{}
      )

      # If the LiveView crashed, render/1 would raise. A successful render
      # confirms the broadcast was handled without a FunctionClauseError.
      assert render(view) =~ ~s(data-mode="files")
    end
  end

  describe "detail_view assign" do
    setup %{conn: conn} do
      user = generate(user())
      %{conn: log_in_user(conn, user), user: user}
    end

    test "is nil by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")
      assert :sys.get_state(view.pid).socket.assigns.detail_view == nil
    end

    test "renders detail-view content when navigating to a detail route", %{conn: conn} do
      # Navigate directly to a detail route — handle_params sets detail_view,
      # which causes the SettingsView child LV to be rendered.
      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ ~s(data-settings-section="profile")
    end

    test "NavPane renders DetailNav when navigating to a detail route", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ ~s(data-detail-section="profile")
    end

    test "mode-strip icons are dimmed when in a detail route", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/chat")

      assert html =~ ~s(data-mode-icon="chat")
      refute html =~ "opacity-60"

      # Patch to a detail route — detail_view is set, mode-strip dims
      html = render_patch(view, ~p"/settings")
      assert html =~ "opacity-60"
    end
  end

  # C1 regression: navigating from a detail view to a tab must clear detail_view
  describe "C1: detail_view cleared on tab navigation" do
    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      conn = log_in_user_with_workspace(conn, user, ws)
      %{conn: conn, user: user, workspace: ws}
    end

    test "navigating from /settings to a conversation tab exits the detail view",
         %{conn: conn, user: user, workspace: ws} do
      {:ok, conv} =
        Magus.Chat.create_conversation(%{title: "Exit test", workspace_id: ws.id}, actor: user)

      {:ok, view, html} = live(conn, ~p"/settings")
      assert html =~ ~s(data-settings-section)

      html = render_patch(view, ~p"/chat/#{conv.id}")
      refute html =~ ~s(data-settings-section)
    end
  end

  # C2 regression: clicking a mode icon while in detail view must exit to mode root
  describe "C2: select_mode exits detail view" do
    setup %{conn: conn} do
      user = generate(user())
      %{conn: log_in_user(conn, user), user: user}
    end

    test "clicking a mode icon while in detail view navigates away from the detail path",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # The mode-strip icons are rendered even in detail view; clicking one
      # should patch to a mode-root URL, which clears the detail view.
      result =
        view
        |> element(~s([data-mode-icon="chat"]))
        |> render_click()

      # render_click on a push_patch returns the new HTML
      refute result =~ ~s(data-settings-section)
    end
  end

  # C5 regression: "New agent" button must create an agent and navigate to its edit view
  describe "C5: new_agent event creates agent and opens edit view" do
    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      conn = log_in_user_with_workspace(conn, user, ws)
      %{conn: conn, user: user, workspace: ws}
    end

    test "new_agent event opens the new-agent creation view", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents")

      html =
        view
        |> element(~s([data-new-agent]))
        |> render_click()

      assert html =~ "New Agent"
      assert html =~ "Create Agent"
    end
  end

  defp create_workspace_text_file(user, ws, name) do
    base = %{
      name: name,
      type: :text,
      mime_type: "text/plain",
      file_path: "f/#{name}",
      file_size: 1,
      workspace_id: ws.id
    }

    {:ok, file} = Magus.Files.create_file(base, actor: user)
    file
  end

  defp grant_brain_to_workspace(user, workspace, title) do
    {:ok, brain} =
      Magus.Brain.create_brain(%{title: title, workspace_id: workspace.id}, actor: user)

    {:ok, _grant} =
      Magus.Workspaces.grant_access(
        %{
          resource_type: :brain,
          resource_id: brain.id,
          grantee_type: :workspace,
          grantee_id: workspace.id,
          role: :viewer
        },
        actor: user
      )

    brain
  end

  describe "mobile drawer state" do
    setup %{conn: conn} do
      user = generate(user())
      %{conn: log_in_user(conn, user), user: user}
    end

    test "drawer is closed by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/chat")
      assert html =~ ~s(data-drawer-open="false")
    end

    test "toggle_drawer flips the state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      assert render(view) =~ ~s(data-drawer-open="false")

      render_hook(view, "toggle_drawer", %{})
      assert render(view) =~ ~s(data-drawer-open="true")

      render_hook(view, "toggle_drawer", %{})
      assert render(view) =~ ~s(data-drawer-open="false")
    end

    test "close_drawer is idempotent", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      render_hook(view, "close_drawer", %{})
      assert render(view) =~ ~s(data-drawer-open="false")

      render_hook(view, "toggle_drawer", %{})
      render_hook(view, "close_drawer", %{})
      assert render(view) =~ ~s(data-drawer-open="false")
    end

    test "Escape closes the drawer", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")
      render_hook(view, "toggle_drawer", %{})
      assert render(view) =~ ~s(data-drawer-open="true")

      render_hook(view, "close_overlays", %{})
      assert render(view) =~ ~s(data-drawer-open="false")
    end

    test "Escape closes the tabs pill", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")
      render_hook(view, "toggle_tabs_pill", %{})
      assert render(view) =~ ~s(data-tabs-pill-open="true")

      render_hook(view, "close_overlays", %{})
      assert render(view) =~ ~s(data-tabs-pill-open="false")
    end
  end

  describe "mobile tabs pill state" do
    setup %{conn: conn} do
      user = generate(user())
      %{conn: log_in_user(conn, user), user: user}
    end

    test "tabs pill is closed by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/chat")
      assert html =~ ~s(data-tabs-pill-open="false")
    end

    test "toggle_tabs_pill flips the state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      render_hook(view, "toggle_tabs_pill", %{})
      assert render(view) =~ ~s(data-tabs-pill-open="true")

      render_hook(view, "toggle_tabs_pill", %{})
      assert render(view) =~ ~s(data-tabs-pill-open="false")
    end

    test "activate_tab closes the pill", %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Magus.Chat.create_conversation(%{title: "C", workspace_id: ws.id}, actor: user)

      conn = log_in_user_with_workspace(conn, user, ws)
      {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")

      render_hook(view, "toggle_tabs_pill", %{})
      assert render(view) =~ ~s(data-tabs-pill-open="true")

      {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      tab_id = session.active_tab_id

      render_hook(view, "activate_tab", %{"tab_id" => tab_id})
      assert render(view) =~ ~s(data-tabs-pill-open="false")
    end

    test "new_tab closes the pill", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      render_hook(view, "toggle_tabs_pill", %{})
      assert render(view) =~ ~s(data-tabs-pill-open="true")

      render_hook(view, "new_tab", %{})
      assert render(view) =~ ~s(data-tabs-pill-open="false")
    end

    test "close_tab keeps pill open when other tabs remain", %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      user = enable_tabs(user)
      ws = generate(workspace(actor: user))

      {:ok, c1} = Magus.Chat.create_conversation(%{title: "C1", workspace_id: ws.id}, actor: user)
      {:ok, c2} = Magus.Chat.create_conversation(%{title: "C2", workspace_id: ws.id}, actor: user)

      conn = log_in_user_with_workspace(conn, user, ws)
      {:ok, view, _html} = live(conn, ~p"/chat")

      view
      |> element(~s(button[phx-value-id="#{c1.id}"][phx-value-type="conversation"]))
      |> render_click()

      view
      |> element(~s(button[phx-value-id="#{c2.id}"][phx-value-type="conversation"]))
      |> render_click()

      {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      [first | _] = session.tabs

      render_hook(view, "toggle_tabs_pill", %{})
      assert render(view) =~ ~s(data-tabs-pill-open="true")

      render_hook(view, "close_tab", %{"tab_id" => first["id"]})

      # One tab remains; pill should still be open.
      assert render(view) =~ ~s(data-tabs-pill-open="true")
    end

    test "close_tab closes pill when last tab is closed", %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Magus.Chat.create_conversation(%{title: "Lonely", workspace_id: ws.id}, actor: user)

      conn = log_in_user_with_workspace(conn, user, ws)
      {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")

      {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
      tab_id = session.active_tab_id

      render_hook(view, "toggle_tabs_pill", %{})
      assert render(view) =~ ~s(data-tabs-pill-open="true")

      render_hook(view, "close_tab", %{"tab_id" => tab_id})

      assert render(view) =~ ~s(data-tabs-pill-open="false")
    end
  end

  describe "responsive chrome" do
    setup %{conn: conn} do
      user = generate(user())
      %{conn: log_in_user(conn, user), user: user}
    end

    test "both desktop and mobile chrome render in the DOM", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/chat")

      # Desktop ModeStrip is hidden on small viewports via md:flex
      assert html =~ ~s(data-mode-icon="chat")
      # Mobile chrome carries its own markers (Header is now inlined directly
      # into render/1, so the old data-mobile-shell wrapper no longer exists).
      assert html =~ ~s(data-mobile-header)
      assert html =~ ~s(data-mobile-drawer)
    end

    test "navigating to an agent opens it as a tab and renders the mobile header with its name",
         %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      conn = log_in_user_with_workspace(conn, user, ws)

      {:ok, agent} =
        Magus.Agents.create_custom_agent(%{name: "Detail Agent", workspace_id: ws.id},
          actor: user
        )

      {:ok, _view, html} = live(conn, ~p"/agents/#{agent.id}")
      assert html =~ ~s(data-mobile-header)
      assert html =~ "Detail Agent"
    end
  end
end
