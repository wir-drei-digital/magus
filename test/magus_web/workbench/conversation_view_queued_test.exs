defmodule MagusWeb.Workbench.ConversationViewQueuedTest do
  use MagusWeb.LiveViewCase, async: false
  import MagusWeb.LiveViewCase
  import Phoenix.LiveViewTest
  import Magus.Generators

  setup %{conn: conn} do
    user = generate(user())
    {:ok, conv} = Magus.Chat.create_conversation(%{title: "q"}, actor: user)
    %{conn: log_in_user(conn, user), user: user, conv: conv}
  end

  defp inner_view(view, conv, user) do
    {:ok, session} = Magus.Workbench.get_tab_session(nil, actor: user)
    tab_id = session.active_tab_id

    view
    |> find_live_child("tab-#{tab_id}")
    |> find_live_child("conversation-#{conv.id}")
  end

  test "queued messages render in a dedicated region", %{conn: conn, user: user, conv: conv} do
    {:ok, _} = Magus.Chat.enqueue_message(conv.id, %{text: "queued one"}, actor: user)

    {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")

    inner = inner_view(view, conv, user)
    assert has_element?(inner, "[data-queued-message]")
  end

  test "enqueue broadcast appends a queued message live", %{conn: conn, user: user, conv: conv} do
    {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")

    inner = inner_view(view, conv, user)
    refute has_element?(inner, "[data-queued-message]")

    {:ok, _} = Magus.Chat.enqueue_message(conv.id, %{text: "live queued"}, actor: user)

    # Re-fetch the inner child so the LiveView re-render is observed.
    inner = inner_view(view, conv, user)
    assert has_element?(inner, "[data-queued-message]")
  end

  test "send (submit) stays present alongside stop while the agent is streaming", %{
    conn: conn,
    user: user,
    conv: conv
  } do
    {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")

    inner = inner_view(view, conv, user)
    # Idle: submit present, stop (cancel) absent.
    assert has_element?(inner, "button[type=submit]")
    refute has_element?(inner, "button[phx-click=stop_response]")

    # Drive the conversation into a streaming state via the real signal path.
    Magus.Agents.Signals.text_chunk(conv.id, Ecto.UUID.generate(), "partial", "partial")

    # Re-fetch the inner child so the LiveView re-render is observed.
    inner = inner_view(view, conv, user)
    # While streaming both the submit (now "Queue") and stop buttons render.
    assert has_element?(inner, "button[type=submit]")
    assert has_element?(inner, "button[phx-click=stop_response]")
  end

  test "a follow-up joins the queue while a message is already queued, even in the inter-tool gap",
       %{conn: conn, user: user, conv: conv} do
    # One message already in the queue (the agent is mid-turn).
    {:ok, _} = Magus.Chat.enqueue_message(conv.id, %{text: "first queued"}, actor: user)

    {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")

    # Drive the turn into the inter-tool gap via the real signal path: the agent
    # streamed a chunk of text, then finished it to call a tool. After
    # text.complete both is_streaming and waiting_for_response are false, so the
    # phase-level agent_running? gate reads false even though the turn is still
    # in progress.
    msg_id = Ecto.UUID.generate()
    Magus.Agents.Signals.text_chunk(conv.id, msg_id, "partial", "partial")
    Magus.Agents.Signals.text_complete(conv.id, msg_id, "partial", nil)

    inner = inner_view(view, conv, user)

    # Drive the composer's parent-notify message straight at the conversation
    # LiveView, which is exactly what ChatInputComponent.notify_parent/1 sends on
    # submit. Going through render_submit instead is flaky: the component's own
    # pre-send guards (modality/compaction checks) depend on async-loaded assigns
    # and sometimes swallow the submit before it reaches the gate under test.
    send(
      inner.pid,
      {MagusWeb.ChatLive.Components.ChatInput.ChatInputComponent,
       {:send_message_with_resources, %{"text" => "second"}, []}}
    )

    # Sync on the LiveView having processed the message.
    _ = render(inner)

    # The second message must JOIN the queue (preserving order), not start a new
    # turn. Before the fix it dispatched a fresh turn and the queue stayed at 1.
    assert length(Magus.Chat.list_queued_messages!(conv.id, actor: user)) == 2
  end

  test "first follow-up during tool execution enqueues (empty queue)", %{
    conn: conn,
    user: user,
    conv: conv
  } do
    {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")

    # Drive a turn into the inter-tool gap via the real signal path with the
    # queue EMPTY: the agent streamed a chunk of text, finished it (text.complete
    # clears is_streaming), then started a tool. During tool execution both
    # is_streaming and waiting_for_response are false, so the phase-level
    # agent_running? gate reads false even though the turn is still in flight.
    msg_id = Ecto.UUID.generate()
    Magus.Agents.Signals.text_chunk(conv.id, msg_id, "partial", "partial")
    Magus.Agents.Signals.text_complete(conv.id, msg_id, "partial", nil)

    Magus.Agents.Signals.broadcast_tool_start(
      conv.id,
      Ecto.UUID.generate(),
      "web_search",
      "Web search",
      %{}
    )

    inner = inner_view(view, conv, user)
    # Nothing queued yet: this is the first follow-up.
    refute has_element?(inner, "[data-queued-message]")

    # Drive the composer's parent-notify message straight at the conversation
    # LiveView, exactly what ChatInputComponent.notify_parent/1 sends on submit.
    # (render_submit is flaky here: the component's own pre-send guards depend on
    # async-loaded assigns and sometimes swallow the submit before the gate.)
    send(
      inner.pid,
      {MagusWeb.ChatLive.Components.ChatInput.ChatInputComponent,
       {:send_message_with_resources, %{"text" => "follow up"}, []}}
    )

    # Sync on the LiveView having processed the message.
    _ = render(inner)

    # The first follow-up must ENQUEUE (a queued region appears) rather than
    # dispatch a second turn. Before the fix the empty-queue branch dispatched.
    inner = inner_view(view, conv, user)
    assert has_element?(inner, "[data-queued-message]")
    assert length(Magus.Chat.list_queued_messages!(conv.id, actor: user)) == 1
  end

  test "remove_queued event removes the queued message", %{conn: conn, user: user, conv: conv} do
    {:ok, msg} = Magus.Chat.enqueue_message(conv.id, %{text: "remove me"}, actor: user)

    {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")

    inner = inner_view(view, conv, user)
    assert has_element?(inner, "[data-queued-message]")

    inner
    |> element(~s([data-queued-message] button[phx-click="remove_queued"]))
    |> render_click()

    inner = inner_view(view, conv, user)
    refute has_element?(inner, "[data-queued-message]")
    assert {:error, _} = Magus.Chat.get_message(msg.id, actor: user)
  end
end
