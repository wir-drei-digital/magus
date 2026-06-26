defmodule MagusWeb.E2E.ChatFlowTest do
  @moduledoc """
  Browser-based E2E tests for the chat flow.

  These tests use Playwright to drive a real browser and verify the complete
  user experience: sending messages, receiving AI responses, and tool execution.
  All LLM calls are mocked — no API keys needed.
  """
  use MagusWeb.PlaywrightCase

  @moduletag :e2e

  describe "basic chat flow" do
    test "user sends message and receives AI response", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      # Mock the LLM streaming response
      stub(LLMMock, :stream_text, fn _model, _context, _opts ->
        MockResponses.stream_text_response("Hello from the AI assistant!")
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      |> assert_has("#chat-textarea")
      |> type("#chat-textarea", "Hello AI!")
      |> click("button[title='Send message']")
      |> assert_has(".prose", text: "Hello from the AI assistant!")
    end
  end

  describe "tool call flow" do
    test "user sends message triggering tool call and sees final response", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      # Use a counter to return different responses on each call.
      # First call: text + tool call for dice_roll
      # Second call: final text response
      call_count = :counters.new(1, [])

      stub(LLMMock, :stream_text, fn _model, _context, _opts ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        if count == 1 do
          MockResponses.stream_text_with_tool_call(
            "Let me roll a dice for you.",
            "dice_roll",
            %{"sides" => 6}
          )
        else
          MockResponses.stream_text_response("I rolled a 4 for you!")
        end
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      |> assert_has("#chat-textarea")
      |> type("#chat-textarea", "Roll a dice for me")
      |> click("button[title='Send message']")
      |> assert_has(".prose", text: "I rolled a 4 for you!")
    end
  end
end
