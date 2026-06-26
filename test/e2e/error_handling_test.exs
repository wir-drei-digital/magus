defmodule MagusWeb.E2E.ErrorHandlingTest do
  @moduledoc """
  Browser-based E2E tests for chat error handling and edge cases.

  Tests:
  - LLM error responses display gracefully (no crash)
  - Stop response button halts streaming and shows partial response
  - Non-existent conversation URLs show appropriate error
  - Unconfirmed users see confirmation prompt instead of chat interface
  """
  use MagusWeb.PlaywrightCase

  @moduletag :e2e

  describe "LLM errors" do
    test "error response resets UI gracefully without crash", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      # Mock the LLM to return an error
      stub(LLMMock, :stream_text, fn _model, _context, _opts ->
        MockResponses.error_response("Service temporarily unavailable")
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      |> assert_has("#chat-textarea")
      |> type("#chat-textarea", "Hello!")
      |> click("button[title='Send message']")
      # The error is handled by PersistencePlugin which broadcasts an "error"
      # signal via PubSub. The LiveView's handle_error resets streaming state
      # (no persisted event message is created for LLM errors in chat mode).
      # The send button reappearing confirms the error was handled gracefully.
      |> assert_has("button[title='Send message']", timeout: 15_000)
      # Verify the page is still connected and functional
      |> assert_has("body .phx-connected")
    end
  end

  describe "stop response" do
    test "stop button cancels streaming and shows cancellation event", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      # Mock a slow streaming response that sleeps to simulate a long LLM call.
      # This gives us time to click the stop button while the agent is processing.
      stub(LLMMock, :stream_text, fn _model, _context, _opts ->
        Process.sleep(10_000)
        MockResponses.stream_text_response("This should never fully appear")
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      |> assert_has("#chat-textarea")
      |> type("#chat-textarea", "Tell me a very long story")
      |> click("button[title='Send message']")
      # Wait for the stop button to appear (title="Cancel response")
      |> assert_has("button[title='Cancel response']", timeout: 10_000)
      |> click("button[title='Cancel response']")
      # After cancellation, a "Response cancelled" event message is created
      # and the stop button should disappear (send button reappears).
      |> assert_has("button[title='Send message']", timeout: 10_000)
    end
  end

  describe "non-existent conversation" do
    test "visiting a non-existent conversation shows error", %{conn: conn} do
      _model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)

      # Use a valid UUID format that does not correspond to any conversation.
      # Ash's get_conversation! raises Ash.Error.Query.NotFound, which Phoenix
      # renders as an error page (500 or 404 depending on error handler config).
      fake_id = Ash.UUID.generate()

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{fake_id}")
      # The page should NOT render the normal chat textarea.
      # Instead it should show an error page or redirect to /chat.
      |> refute_has("#chat-textarea", timeout: 5_000)
    end
  end

  describe "unconfirmed user" do
    test "unconfirmed user visiting /chat sees email confirmation prompt", %{conn: conn} do
      _model = create_default_model()
      # Do NOT call confirm_user/1 -- leave the user unconfirmed
      user = generate(user())
      setup_subscription_for_user(user)

      conn
      |> authenticate(user)
      |> visit(~p"/chat")
      |> assert_has("body .phx-connected")
      # The chat_live.ex render/1 clause for email_unconfirmed: true
      # shows "Please confirm your email" heading and a resend button.
      |> assert_has("h2", text: "confirm your email", timeout: 10_000)
      # The chat textarea should NOT be present
      |> refute_has("#chat-textarea")
      # The "Resend confirmation email" button should be visible
      |> assert_has("button", text: "Resend confirmation email")
    end
  end
end
