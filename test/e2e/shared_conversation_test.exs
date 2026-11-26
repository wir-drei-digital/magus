defmodule MagusWeb.E2E.SharedConversationTest do
  @moduledoc """
  Browser-based E2E tests for sharing conversations via share links.

  Tests the full shared conversation flow: creating share links programmatically,
  visiting the shared URL as an unauthenticated user, and verifying the read-only
  view displays messages without a chat input.
  """
  use MagusWeb.PlaywrightCase

  import Fluffy.Expect, only: [expect: 2, to_have_count: 2]
  import Fluffy.Locator, only: [by_css: 1, by_role: 2, by_text: 2]

  alias Magus.Chat.Message

  @moduletag :e2e

  describe "shared conversations" do
    test "public share link shows read-only conversation with messages", %{session: session} do
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

      # Visit share link as unauthenticated user
      session
      |> Fluffy.visit(~p"/shared/#{share_link.token}")
      # Verify conversation info bar is shown
      |> assert_has(by_text("Shared conversation", exact: true))
      |> assert_has(by_text("Read-only", exact: true))
      # Verify both messages are visible
      |> assert_has(by_text("Hello from the owner!", exact: true))
      |> assert_has(by_text("Hello! I am the AI assistant.", exact: true))
      # The read-only view has no visible chat input.
      |> refute_has(by_css("#chat-textarea"))
    end

    test "shared view displays conversation title", %{session: session} do
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

      session
      |> Fluffy.visit(~p"/shared/#{share_link.token}")
      |> assert_has(by_role(:heading, level: 1, name: "My Shared Discussion", exact: true))
    end

    test "invalid share token shows not found error", %{session: session} do
      session
      |> Fluffy.visit(~p"/shared/invalid-nonexistent-token")
      |> assert_has(by_role(:heading, name: "Link Not Found", exact: true))
      |> assert_has(by_text("This share link is invalid or has been revoked.", exact: true))
    end

    test "revoked share link shows not found error", %{session: session} do
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

      session
      |> Fluffy.visit(~p"/shared/#{share_link.token}")
      |> assert_has(by_role(:heading, name: "Link Not Found", exact: true))
      |> expect(to_have_count(by_text("Secret message", exact: false), 0))
    end

    test "authenticated share link requires login for unauthenticated visitor", %{
      session: session
    } do
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
      session
      |> Fluffy.visit(~p"/shared/#{share_link.token}")
      |> assert_has(by_role(:heading, name: "Login Required", exact: true))
      |> assert_has(by_role(:link, name: "Sign In", exact: true))
      |> expect(to_have_count(by_text("Private content", exact: false), 0))
    end

    test "authenticated share link is accessible to logged-in user", %{session: session} do
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
      session
      |> authenticate(viewer)
      |> Fluffy.visit(~p"/shared/#{share_link.token}")
      |> assert_has(by_text("Shared conversation", exact: true))
      |> assert_has(by_text("Authenticated content", exact: true))
      |> refute_has(by_css("#chat-textarea"))
    end
  end
end
