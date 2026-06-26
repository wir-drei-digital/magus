defmodule MagusWeb.Workbench.Tab.RailPanelEventsTest do
  @moduledoc """
  Verifies that notify_parent messages from the rail's panel components
  (LibrarySidebarComponent, DraftsSidebarComponent) are handled by the
  ConversationView that hosts the header popover, then propagated across the
  tab topic where needed.

  These tests simulate the notify_parent send directly to the ConversationView
  LV process, since reaching into the legacy panel components' internal
  click handlers would couple the tests to their markup.
  """
  use MagusWeb.LiveViewCase, async: false
  import MagusWeb.LiveViewCase
  import Phoenix.LiveViewTest
  import Magus.Generators
  import MagusWeb.Workbench.TestHelpers

  alias MagusWeb.ChatLive.Components.Brain.BrainSidebarComponent
  alias MagusWeb.ChatLive.Components.Library.DraftsSidebarComponent
  alias MagusWeb.ChatLive.Components.Library.LibrarySidebarComponent

  setup %{conn: conn} do
    user = generate(user())
    {:ok, conv} = Magus.Chat.create_conversation(%{title: "C"}, actor: user)
    %{conn: log_in_user(conn, user), user: user, conv: conv}
  end

  defp tab_view(view, user) do
    {:ok, session} = Magus.Workbench.get_tab_session(nil, actor: user)
    find_live_child(view, "tab-#{session.active_tab_id}")
  end

  defp conv_view(view, user, conv) do
    view
    |> tab_view(user)
    |> find_live_child("conversation-#{conv.id}")
  end

  describe "prompts panel" do
    test "activate persists system_prompt_id and reflects in ConversationView",
         %{conn: conn, user: user, conv: conv} do
      {:ok, prompt} =
        Magus.Library.create_prompt(%{name: "P", content: "be helpful", type: :system},
          actor: user
        )

      {:ok, view, _} = live(conn, ~p"/chat/#{conv.id}")
      conversation = conv_view(view, user, conv)

      send(conversation.pid, {LibrarySidebarComponent, {:activate_system_prompt, prompt}})

      :ok =
        poll_until(fn ->
          {:ok, c} = Magus.Chat.get_conversation(conv.id, actor: user)
          c.system_prompt_id == prompt.id
        end)

      # ConversationView (sibling LV) updates its active_system_prompt assign
      # via PubSub on the tab topic.
      :ok = poll_until(fn -> render(conversation) =~ prompt.name end)
    end

    test "deactivate clears system_prompt_id",
         %{conn: conn, user: user, conv: conv} do
      {:ok, prompt} =
        Magus.Library.create_prompt(%{name: "P", content: "x", type: :system}, actor: user)

      {:ok, conv} = Magus.Chat.activate_system_prompt(conv, prompt.id, actor: user)
      assert conv.system_prompt_id == prompt.id

      {:ok, view, _} = live(conn, ~p"/chat/#{conv.id}")
      conversation = conv_view(view, user, conv)

      send(conversation.pid, {LibrarySidebarComponent, :deactivate_system_prompt})

      :ok =
        poll_until(fn ->
          {:ok, c} = Magus.Chat.get_conversation(conv.id, actor: user)
          is_nil(c.system_prompt_id)
        end)
    end

    test "insert_prompt_content broadcasts text on the tab topic",
         %{conn: conn, user: user, conv: conv} do
      {:ok, prompt} =
        Magus.Library.create_prompt(%{name: "P", content: "Hello there", type: :user},
          actor: user
        )

      {:ok, view, _} = live(conn, ~p"/chat/#{conv.id}")
      {:ok, session} = Magus.Workbench.get_tab_session(nil, actor: user)

      # Subscribe BEFORE triggering so we observe the broadcast that
      # TabContainer makes in response to the panel notify_parent.
      Phoenix.PubSub.subscribe(
        Magus.PubSub,
        MagusWeb.Workbench.Signals.tab_topic(session.active_tab_id)
      )

      conversation = conv_view(view, user, conv)
      send(conversation.pid, {LibrarySidebarComponent, {:insert_prompt_content, prompt}})

      assert_receive {:workbench_chrome, {:insert_text, "Hello there"}}, 500
    end
  end

  describe "brains panel" do
    test "open_brain_page opens the page as a brain_page companion",
         %{conn: conn, user: user, conv: conv} do
      {:ok, brain} = Magus.Brain.create_brain(%{title: "B"}, actor: user)
      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "P"}, actor: user)

      {:ok, view, _} = live(conn, ~p"/chat/#{conv.id}")
      conversation = conv_view(view, user, conv)

      send(conversation.pid, {BrainSidebarComponent, {:open_brain_page, brain.id, page.id}})

      :ok = poll_until(fn -> render(view) =~ ~s(data-companion-type="brain_page") end)
    end
  end

  describe "drafts panel" do
    test "switch_draft opens the draft as a companion",
         %{conn: conn, user: user, conv: conv} do
      {:ok, draft} =
        Magus.Drafts.create_draft(conv.id, "D", "draft body", user.id, actor: user)

      {:ok, view, _} = live(conn, ~p"/chat/#{conv.id}")
      conversation = conv_view(view, user, conv)

      send(conversation.pid, {DraftsSidebarComponent, {:switch_draft, draft.id}})

      :ok = poll_until(fn -> render(view) =~ ~s(data-companion-type="draft") end)
    end

    test "delete_draft removes the draft from the database",
         %{conn: conn, user: user, conv: conv} do
      {:ok, draft} =
        Magus.Drafts.create_draft(conv.id, "D", "draft body", user.id, actor: user)

      {:ok, view, _} = live(conn, ~p"/chat/#{conv.id}")
      conversation = conv_view(view, user, conv)

      send(conversation.pid, {DraftsSidebarComponent, {:delete_draft, draft.id}})

      :ok =
        poll_until(fn -> match?({:error, _}, Magus.Drafts.get_draft(draft.id, actor: user)) end)
    end
  end

  describe "drag-and-drop into chat" do
    test "activate_system_prompt_by_id event activates the prompt",
         %{conn: conn, user: user, conv: conv} do
      {:ok, prompt} =
        Magus.Library.create_prompt(%{name: "Drop", content: "x", type: :system}, actor: user)

      {:ok, view, _} = live(conn, ~p"/chat/#{conv.id}")
      cv = conv_view(view, user, conv)

      render_hook(cv, "activate_system_prompt_by_id", %{"prompt_id" => prompt.id})

      :ok =
        poll_until(fn ->
          {:ok, c} = Magus.Chat.get_conversation(conv.id, actor: user)
          c.system_prompt_id == prompt.id
        end)
    end
  end
end
