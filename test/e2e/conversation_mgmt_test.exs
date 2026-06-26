defmodule MagusWeb.E2E.ConversationMgmtTest do
  @moduledoc """
  Browser-based E2E tests for conversation management features in the chat sidebar.

  Tests cover:
  - Creating new conversations from the blank chat state
  - Verifying conversations appear in the sidebar
  - Renaming conversations via the right sidebar title edit
  - Favoriting conversations
  - Creating folders
  - Deleting conversations from the sidebar
  """
  use MagusWeb.PlaywrightCase

  @moduletag :e2e

  describe "new conversation" do
    test "sending first message creates conversation", %{conn: conn} do
      _model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)

      stub(LLMMock, :stream_text, fn _model, _context, _opts ->
        MockResponses.stream_text_response("Hello! How can I help you?")
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat")
      |> assert_has("body .phx-connected")
      # Blank chat state shows the prompt text
      |> assert_has("p", text: "What's on your mind today?")
      |> assert_has("#chat-textarea")
      |> type("#chat-textarea", "Hi there")
      |> click("button[title='Send message']")
      # After sending, the AI response appears
      |> assert_has(".prose", text: "Hello! How can I help you?")
      # URL should now contain a conversation ID (no longer just /chat)
      |> refute_has("p", text: "What's on your mind today?")
    end
  end

  describe "conversation appears in sidebar" do
    test "newly created conversation shows in the left sidebar", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      stub(LLMMock, :stream_text, fn _model, _context, _opts ->
        MockResponses.stream_text_response("Sure thing!")
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      # The conversation should appear in the sidebar tree view
      |> assert_has("[id^='conv-item-']")
      # Verify the conversation link is present (navigates to this conversation)
      |> assert_has("a[href='/chat/#{conversation.id}']")
    end
  end

  describe "rename conversation" do
    test "edit conversation title inline via the right sidebar", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)

      conversation =
        generate(
          conversation(
            actor: user,
            selected_model_id: model.id,
            title: "Original Title"
          )
        )

      stub(LLMMock, :stream_text, fn _model, _context, _opts ->
        MockResponses.stream_text_response("Got it!")
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      # The title should display in the right sidebar conversation info
      |> assert_has("h2", text: "Original Title")
      # Click the title to start editing (owner can edit)
      |> click("h2[phx-click='start_edit_title']")
      # The title input form should appear
      |> assert_has("form[phx-submit='save_title'] input[name='title']")
      # Select all existing text and type new title
      |> press("input[name='title']", "Control+a")
      |> type("input[name='title']", "Renamed Conversation")
      # Submit the form
      |> click("form[phx-submit='save_title'] button[type='submit']")
      # After saving, the new title should display
      |> assert_has("h2", text: "Renamed Conversation")
    end
  end

  describe "favorite conversation" do
    test "star a conversation and it appears in favorites section", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)

      conversation =
        generate(
          conversation(
            actor: user,
            selected_model_id: model.id,
            title: "My Favorite Chat"
          )
        )

      stub(LLMMock, :stream_text, fn _model, _context, _opts ->
        MockResponses.stream_text_response("Hello!")
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      # Initially there should be no favorites section in the sidebar
      |> refute_has("span", text: "Favorites")
      # Click the favorite button in the right sidebar
      |> click("button[title='Add to favorites']")
      # Now the favorites section should appear in the sidebar
      |> assert_has("span", text: "Favorites")
      # The star icon should be filled (indicating favorited state)
      |> assert_has("button[title='Remove from favorites']")
    end
  end

  describe "create folder" do
    test "create a new folder in the sidebar", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      stub(LLMMock, :stream_text, fn _model, _context, _opts ->
        MockResponses.stream_text_response("Hello!")
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      # Click the "New Folder" button in the sidebar header
      |> click("button[title='New Folder']")
      # The folder modal should open
      |> assert_has("h3", text: "New Folder")
      # Fill in the folder name
      |> fill_in("Folder Name", with: "My Project")
      # Click create
      |> click_button("Create")
      # The folder should appear in the sidebar
      |> assert_has("span", text: "My Project")
    end
  end

  describe "delete conversation" do
    test "delete a conversation from the sidebar", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)

      conversation =
        generate(
          conversation(
            actor: user,
            selected_model_id: model.id,
            title: "Delete Me"
          )
        )

      # Create a second conversation so we have something remaining
      _other_conversation =
        generate(
          conversation(
            actor: user,
            selected_model_id: model.id,
            title: "Keep Me"
          )
        )

      stub(LLMMock, :stream_text, fn _model, _context, _opts ->
        MockResponses.stream_text_response("Hello!")
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      # The conversation should be in the sidebar
      |> assert_has("span", text: "Delete Me")
      # Click the delete button on the conversation item
      # The delete button is inside the conversation item with phx-click="delete_conversation"
      |> click("[id='conv-item-#{conversation.id}'] button[phx-click='delete_conversation']")
      # The conversation should no longer appear in the sidebar
      |> refute_has("span", text: "Delete Me")
      # The other conversation should still be there
      |> assert_has("span", text: "Keep Me")
    end
  end
end
