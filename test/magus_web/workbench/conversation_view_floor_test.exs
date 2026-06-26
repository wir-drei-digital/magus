defmodule MagusWeb.Workbench.ConversationViewFloorTest do
  use MagusWeb.LiveViewCase, async: false
  import MagusWeb.LiveViewCase
  import Phoenix.LiveViewTest
  import Magus.Generators

  setup %{conn: conn} do
    user = generate(user())
    {:ok, conv} = Magus.Chat.create_conversation(%{title: "f"}, actor: user)
    %{conn: log_in_user(conn, user), user: user, conv: conv}
  end

  defp inner_view(view, conv, user) do
    {:ok, session} = Magus.Workbench.get_tab_session(nil, actor: user)
    tab_id = session.active_tab_id

    view
    |> find_live_child("tab-#{tab_id}")
    |> find_live_child("conversation-#{conv.id}")
  end

  test "floor divider renders at the context floor when older messages are out of window", %{
    conn: conn,
    user: user,
    conv: conv
  } do
    # Create a few messages; these become the out-of-window history once the
    # floor advances past them.
    for i <- 1..3 do
      {:ok, _} =
        Magus.Chat.create_message(%{text: "m#{i}", conversation_id: conv.id}, actor: user)
    end

    # Clear advances the floor past the latest message, so everything created so
    # far is out-of-window.
    {:ok, _} = Magus.Chat.clear_context_for_conversation(conv.id, actor: user)

    # A later message lands in-window (after the floor); it becomes the boundary.
    {:ok, _} =
      Magus.Chat.create_message(%{text: "after", conversation_id: conv.id}, actor: user)

    {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")
    inner = inner_view(view, conv, user)

    assert has_element?(inner, "[data-role=context-floor-divider]")
  end

  test "no floor divider when every loaded message is in-window", %{
    conn: conn,
    user: user,
    conv: conv
  } do
    # Messages exist but the floor has never advanced past them, so they are all
    # in-window and there is no out-of-window history to separate.
    for i <- 1..3 do
      {:ok, _} =
        Magus.Chat.create_message(%{text: "m#{i}", conversation_id: conv.id}, actor: user)
    end

    {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")
    inner = inner_view(view, conv, user)

    refute has_element?(inner, "[data-role=context-floor-divider]")
  end

  test "floor divider appears live when a compaction advances the floor (no reload)", %{
    conn: conn,
    user: user,
    conv: conv
  } do
    # Five in-window messages. With the floor still at the start, none are
    # out-of-window, so there is no divider yet.
    msgs =
      for i <- 1..5 do
        {:ok, m} =
          Magus.Chat.create_message(%{text: "m#{i}", conversation_id: conv.id}, actor: user)

        m
      end

    {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")
    inner = inner_view(view, conv, user)
    refute has_element?(inner, "[data-role=context-floor-divider]")

    # Simulate a completed compaction pass: advance the floor to m4 (so m1-m3
    # are summarized/out-of-window) and store a summary. Mirrors the terminal
    # write RunCompaction performs.
    boundary = Enum.at(msgs, 3)
    {:ok, cw} = Magus.Chat.get_or_create_context_window(conv.id, actor: user)

    {:ok, _} =
      Magus.Chat.compact_context_window(
        cw,
        %{
          summary: "Earlier messages summarized.",
          summary_message_count: 3,
          window_start_message_id: boundary.id,
          window_start_at: boundary.inserted_at
        },
        actor: user
      )

    # Replay the broadcast RunCompaction emits on completion. The divider must
    # appear without re-mounting the LiveView.
    Magus.Agents.Signals.context_updated(conv.id, %{})

    inner = inner_view(view, conv, user)
    assert has_element?(inner, "[data-role=context-floor-divider]")
  end

  test "a compacted floor renders an expandable summary toggle", %{
    conn: conn,
    user: user,
    conv: conv
  } do
    msgs =
      for i <- 1..5 do
        {:ok, m} =
          Magus.Chat.create_message(%{text: "m#{i}", conversation_id: conv.id}, actor: user)

        m
      end

    boundary = Enum.at(msgs, 3)
    {:ok, cw} = Magus.Chat.get_or_create_context_window(conv.id, actor: user)

    {:ok, _} =
      Magus.Chat.compact_context_window(
        cw,
        %{
          summary: "A recap of the earlier discussion.",
          summary_message_count: 3,
          window_start_message_id: boundary.id,
          window_start_at: boundary.inserted_at
        },
        actor: user
      )

    {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")
    inner = inner_view(view, conv, user)

    # The divider is interactive (a <details> toggle) and the summary text is
    # present in the DOM to reveal on expand.
    assert has_element?(inner, "[data-role=context-floor-toggle]")

    assert has_element?(
             inner,
             "[data-role=context-floor-summary]",
             "A recap of the earlier discussion."
           )
  end

  test "clearing surfaces the floor divider immediately, before any new message", %{
    conn: conn,
    user: user,
    conv: conv
  } do
    for i <- 1..3 do
      {:ok, _} =
        Magus.Chat.create_message(%{text: "m#{i}", conversation_id: conv.id}, actor: user)
    end

    {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")
    inner = inner_view(view, conv, user)
    refute has_element?(inner, "[data-role=context-floor-divider]")

    # Clear advances the floor past every current message. Nothing is in-window
    # yet, but the divider must still appear (anchored to the last message) so
    # the user can see the clear took effect — without waiting for a new message.
    {:ok, _} = Magus.Chat.clear_context_for_conversation(conv.id, actor: user)
    Magus.Agents.Signals.context_updated(conv.id, %{})

    inner = inner_view(view, conv, user)
    assert has_element?(inner, "[data-role=context-floor-divider]")
  end

  test "the floor divider anchors to the last out-of-window message, not the latest", %{
    user: user,
    conv: conv
  } do
    msgs =
      for i <- 1..5 do
        {:ok, m} =
          Magus.Chat.create_message(%{text: "m#{i}", conversation_id: conv.id}, actor: user)

        m
      end

    [m1, _m2, m3, _m4, _m5] = msgs

    # Floor sits just after m3: m1..m3 are out of window, m4/m5 are in-window.
    floor = DateTime.add(m3.inserted_at, 1, :microsecond)

    # The divider must anchor to m3 (the NEWEST out-of-window message) so it
    # renders just below it and stays put as m4/m5 (and later messages)
    # accumulate — rather than riding the first in-window message / the latest.
    assert MagusWeb.ChatLive.Helpers.floor_boundary_id(conv.id, m1.inserted_at, floor, user) ==
             m3.id
  end

  test "an out-of-context floor (no summary) renders a plain, non-interactive divider", %{
    conn: conn,
    user: user,
    conv: conv
  } do
    msgs =
      for i <- 1..5 do
        {:ok, m} =
          Magus.Chat.create_message(%{text: "m#{i}", conversation_id: conv.id}, actor: user)

        m
      end

    # Advance the floor mid-stream WITHOUT a summary (the rolling/cleared case):
    # older messages are simply out of context.
    boundary = Enum.at(msgs, 3)
    {:ok, cw} = Magus.Chat.get_or_create_context_window(conv.id, actor: user)

    {:ok, _} =
      Magus.Chat.compact_context_window(
        cw,
        %{
          summary: nil,
          summary_message_count: 0,
          window_start_message_id: boundary.id,
          window_start_at: boundary.inserted_at
        },
        actor: user
      )

    {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")
    inner = inner_view(view, conv, user)

    assert has_element?(inner, "[data-role=context-floor-divider]")
    refute has_element?(inner, "[data-role=context-floor-toggle]")
    refute has_element?(inner, "[data-role=context-floor-summary]")
  end
end
