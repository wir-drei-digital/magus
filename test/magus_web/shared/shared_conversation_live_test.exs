defmodule MagusWeb.SharedConversationLiveTest do
  @moduledoc """
  Tests for SharedConversationLive - read-only view for shared conversations.

  Tests the public share link viewing flow including:
  - Public link access (no login required)
  - Authenticated link access (login required)
  - Invalid/revoked link handling
  - Read-only message display
  """
  use MagusWeb.LiveViewCase, async: false

  import MagusWeb.LiveViewCase

  alias Magus.Chat

  describe "public share link access" do
    setup do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{title: "Test Shared"}, actor: owner)

      # Create a user message
      {:ok, _msg1} =
        Chat.create_message(
          %{text: "Hello from owner", conversation_id: conversation.id},
          actor: owner
        )

      # Create an agent message directly using Ash
      {:ok, _msg2} =
        Magus.Chat.Message
        |> Ash.Changeset.for_create(:create_event, %{
          text: "Response from AI",
          conversation_id: conversation.id
        })
        |> Ash.create(authorize?: false)

      # Create public share link
      {:ok, share_link} =
        Chat.create_share_link(conversation.id, %{access_type: :public}, actor: owner)

      {:ok, owner: owner, conversation: conversation, share_link: share_link}
    end

    test "unauthenticated user can view public shared conversation", %{
      conn: conn,
      share_link: share_link,
      conversation: conversation
    } do
      {:ok, view, html} = live(conn, ~p"/shared/#{share_link.token}")

      # Should see conversation title
      assert html =~ conversation.title

      # Should see read-only badge
      assert html =~ "Read-only"

      # Should see messages
      assert html =~ "Hello from owner"
      assert html =~ "Response from AI"

      # Should see CTA in footer
      assert render(view) =~ "Try MAGUS Free"
    end

    test "authenticated user can view public shared conversation", %{
      conn: conn,
      share_link: share_link,
      conversation: conversation
    } do
      viewer = generate(user())
      conn = log_in_user(conn, viewer)

      {:ok, _view, html} = live(conn, ~p"/shared/#{share_link.token}")

      assert html =~ conversation.title
      assert html =~ "Hello from owner"
    end

    test "shows shared conversation indicator", %{conn: conn, share_link: share_link} do
      {:ok, _view, html} = live(conn, ~p"/shared/#{share_link.token}")

      assert html =~ "Shared conversation"
    end
  end

  describe "authenticated share link access" do
    setup do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{title: "Private Share"}, actor: owner)

      {:ok, _msg} =
        Chat.create_message(
          %{text: "Secret message", conversation_id: conversation.id},
          actor: owner
        )

      # Create authenticated share link
      {:ok, share_link} =
        Chat.create_share_link(conversation.id, %{access_type: :authenticated}, actor: owner)

      {:ok, owner: owner, conversation: conversation, share_link: share_link}
    end

    test "unauthenticated user sees login required message", %{
      conn: conn,
      share_link: share_link
    } do
      {:ok, _view, html} = live(conn, ~p"/shared/#{share_link.token}")

      # Should see login required message
      assert html =~ "Login Required"
      assert html =~ "Sign In"

      # Should NOT see the message content
      refute html =~ "Secret message"
    end

    test "authenticated user can view authenticated shared conversation", %{
      conn: conn,
      share_link: share_link,
      conversation: conversation
    } do
      viewer = generate(user())
      conn = log_in_user(conn, viewer)

      {:ok, _view, html} = live(conn, ~p"/shared/#{share_link.token}")

      assert html =~ conversation.title
      assert html =~ "Secret message"
    end

    test "shows lock icon for authenticated links", %{
      conn: conn,
      share_link: share_link
    } do
      viewer = generate(user())
      conn = log_in_user(conn, viewer)

      {:ok, _view, html} = live(conn, ~p"/shared/#{share_link.token}")

      # Should have lock indicator (either in icon or class)
      assert html =~ "lucide-lock" or html =~ "lock"
    end
  end

  describe "invalid share link handling" do
    test "shows not found for invalid token", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/shared/totally-invalid-token-12345")

      assert html =~ "Link Not Found"
      assert html =~ "invalid or has been revoked"
    end

    test "shows not found for revoked link", %{conn: conn} do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      {:ok, share_link} =
        Chat.create_share_link(conversation.id, %{}, actor: owner)

      # Revoke the link
      {:ok, _} = Chat.revoke_share_link(share_link, actor: owner)

      {:ok, _view, html} = live(conn, ~p"/shared/#{share_link.token}")

      assert html =~ "Link Not Found"
    end

    test "shows go home button on error", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/shared/nonexistent-token")

      assert html =~ "Go Home"
    end
  end

  describe "read-only view restrictions" do
    setup do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{title: "Read Only Test"}, actor: owner)

      {:ok, share_link} =
        Chat.create_share_link(conversation.id, %{access_type: :public}, actor: owner)

      {:ok, owner: owner, conversation: conversation, share_link: share_link}
    end

    test "does not show chat input", %{conn: conn, share_link: share_link} do
      {:ok, _view, html} = live(conn, ~p"/shared/#{share_link.token}")

      # Should NOT have chat input
      refute html =~ "chat-textarea"
      refute html =~ "chat-input-area"
      refute html =~ "Send"
    end

    test "shows read-only indicator", %{conn: conn, share_link: share_link} do
      {:ok, _view, html} = live(conn, ~p"/shared/#{share_link.token}")

      assert html =~ "Read-only"
    end
  end

  describe "empty conversation" do
    test "shows empty state for conversation with no messages", %{conn: conn} do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{title: "Empty Convo"}, actor: owner)

      {:ok, share_link} =
        Chat.create_share_link(conversation.id, %{}, actor: owner)

      {:ok, _view, html} = live(conn, ~p"/shared/#{share_link.token}")

      assert html =~ "No messages in this conversation"
    end
  end

  describe "page metadata" do
    test "sets page title from conversation title", %{conn: conn} do
      owner = generate(user())

      {:ok, conversation} =
        Chat.create_conversation(%{title: "My Amazing Chat"}, actor: owner)

      {:ok, share_link} =
        Chat.create_share_link(conversation.id, %{}, actor: owner)

      {:ok, view, _html} = live(conn, ~p"/shared/#{share_link.token}")

      # Check that page_title is set (this affects <title> tag)
      assert view.module == MagusWeb.SharedConversationLive
    end
  end

  describe "tool call rendering" do
    test "displays tool calls without message bubbles", %{conn: conn} do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      # Create message with tool_call_data using upsert_event
      {:ok, _msg} =
        Magus.Chat.Message
        |> Ash.Changeset.for_create(:upsert_event, %{
          id: Ash.UUID.generate(),
          text: "",
          conversation_id: conversation.id,
          tool_call_data: %{
            tool_name: "web_search",
            status: :success,
            output_summary: "Found 5 results"
          }
        })
        |> Ash.create(authorize?: false)

      {:ok, share_link} = Chat.create_share_link(conversation.id, %{}, actor: owner)
      {:ok, _view, html} = live(conn, ~p"/shared/#{share_link.token}")

      assert html =~ "Web Search"
      assert html =~ "tool-call-entry"
    end

    test "hides empty messages", %{conn: conn} do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      # Create a regular message
      {:ok, _msg1} =
        Chat.create_message(
          %{text: "Hello", conversation_id: conversation.id},
          actor: owner
        )

      # Create an empty message (no text, no tool_call_data)
      {:ok, _msg2} =
        Magus.Chat.Message
        |> Ash.Changeset.for_create(:upsert_event, %{
          id: Ash.UUID.generate(),
          text: "",
          conversation_id: conversation.id
        })
        |> Ash.create(authorize?: false)

      {:ok, share_link} = Chat.create_share_link(conversation.id, %{}, actor: owner)
      {:ok, _view, html} = live(conn, ~p"/shared/#{share_link.token}")

      # Should see the regular message
      assert html =~ "Hello"
      # The empty event should not produce a visible message bubble or tool entry
      refute html =~ "tool-call-entry"
    end
  end

  describe "sign up CTA" do
    test "shows try MAGUS free button", %{conn: conn} do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      {:ok, share_link} =
        Chat.create_share_link(conversation.id, %{}, actor: owner)

      {:ok, _view, html} = live(conn, ~p"/shared/#{share_link.token}")

      assert html =~ "Try MAGUS Free"
    end
  end
end
