defmodule MagusWeb.E2E.SharedConversationTest do
  @moduledoc """
  Browser-based E2E tests for sharing conversations via share links.

  Tests the full shared conversation flow: creating share links programmatically,
  visiting the shared URL as an unauthenticated user, and verifying the read-only
  view displays messages without a chat input.
  """
  use MagusWeb.PlaywrightCase

  alias Magus.Chat.Message

  @moduletag :e2e

  describe "shared conversations" do
    test "public share link shows read-only conversation with messages", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      # Create user and agent messages in the conversation
      generate(
        message(actor: user, conversation_id: conversation.id, text: "Hello from the owner!")
      )

      Message
      |> Ash.Changeset.for_create(:upsert_response, %{
        id: Ash.UUIDv7.generate(),
        text: "Hello! I am the AI assistant.",
        conversation_id: conversation.id,
        complete: true
      })
      |> Ash.create!(actor: %Magus.Agents.Support.AiAgent{})

      # Create a public share link programmatically
      {:ok, share_link} =
        Chat.create_share_link(
          conversation.id,
          %{access_type: :public},
          actor: user
        )

      # Visit share link as unauthenticated user (fresh conn, no authenticate call)
      conn
      |> visit(~p"/shared/#{share_link.token}")
      |> assert_has(".phx-connected")
      # Verify conversation info bar is shown
      |> assert_has("body", text: "Shared conversation")
      |> assert_has("body", text: "Read-only")
      # Verify both messages are visible
      |> assert_has("body", text: "Hello from the owner!")
      |> assert_has("body", text: "Hello! I am the AI assistant.")
      # Assert no chat input is present (read-only view)
      |> refute_has("#chat-textarea")
    end

    test "shared view displays conversation title", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)

      conversation =
        generate(
          conversation(
            actor: user,
            selected_model_id: model.id,
            title: "My Shared Discussion"
          )
        )

      generate(message(actor: user, conversation_id: conversation.id, text: "A test message"))

      {:ok, share_link} =
        Chat.create_share_link(
          conversation.id,
          %{access_type: :public},
          actor: user
        )

      conn
      |> visit(~p"/shared/#{share_link.token}")
      |> assert_has(".phx-connected")
      |> assert_has("h1", text: "My Shared Discussion")
    end

    test "invalid share token shows not found error", %{conn: conn} do
      conn
      |> visit(~p"/shared/invalid-nonexistent-token")
      |> assert_has(".phx-connected")
      |> assert_has("body", text: "Link Not Found")
      |> assert_has("body", text: "invalid or has been revoked")
    end

    test "revoked share link shows not found error", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      generate(message(actor: user, conversation_id: conversation.id, text: "Secret message"))

      {:ok, share_link} =
        Chat.create_share_link(
          conversation.id,
          %{access_type: :public},
          actor: user
        )

      # Revoke the link
      {:ok, _} = Chat.revoke_share_link(share_link, actor: user)

      conn
      |> visit(~p"/shared/#{share_link.token}")
      |> assert_has(".phx-connected")
      |> assert_has("body", text: "Link Not Found")
      # Ensure the message content is NOT visible
      |> refute_has("body", text: "Secret message")
    end

    test "authenticated share link requires login for unauthenticated visitor", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      generate(message(actor: user, conversation_id: conversation.id, text: "Private content"))

      {:ok, share_link} =
        Chat.create_share_link(
          conversation.id,
          %{access_type: :authenticated},
          actor: user
        )

      # Visit as unauthenticated user
      conn
      |> visit(~p"/shared/#{share_link.token}")
      |> assert_has(".phx-connected")
      |> assert_has("body", text: "Login Required")
      |> assert_has("a", text: "Sign In")
      # Ensure the message content is NOT visible
      |> refute_has("body", text: "Private content")
    end

    test "authenticated share link is accessible to logged-in user", %{conn: conn} do
      model = create_default_model()
      owner = generate(user()) |> confirm_user()
      viewer = generate(user()) |> confirm_user()
      setup_subscription_for_user(owner)

      conversation = generate(conversation(actor: owner, selected_model_id: model.id))

      generate(
        message(actor: owner, conversation_id: conversation.id, text: "Authenticated content")
      )

      {:ok, share_link} =
        Chat.create_share_link(
          conversation.id,
          %{access_type: :authenticated},
          actor: owner
        )

      # Visit as a different authenticated user
      conn
      |> authenticate(viewer)
      |> visit(~p"/shared/#{share_link.token}")
      |> assert_has(".phx-connected")
      |> assert_has("body", text: "Shared conversation")
      |> assert_has("body", text: "Authenticated content")
      |> refute_has("#chat-textarea")
    end
  end
end
