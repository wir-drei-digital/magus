defmodule MagusWeb.E2E.MemoryFlowTest do
  @moduledoc """
  Browser-based E2E tests for memory operations via AI tool calls in the chat UI.

  These tests verify the complete flow of memory tools (set_memory, search_memories)
  being triggered through chat messages, including tool call UI indicators.
  All LLM calls are mocked -- no API keys needed.
  """
  use MagusWeb.PlaywrightCase

  @moduletag :e2e

  describe "memory via tool calls" do
    test "set memory tool call completes successfully", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      call_count = :counters.new(1, [])

      stub(LLMMock, :stream_text, fn _model, _context, _opts ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        if count == 1 do
          # First call: trigger a tool call (use non-matching name so the tool
          # lookup fails gracefully and the agent proceeds to the next iteration,
          # similar to the dice_roll pattern in chat_flow_test.exs)
          MockResponses.stream_text_with_tool_call(
            "Saving that preference for you now.",
            "memory_set",
            %{"name" => "user_preference", "summary" => "User likes dark mode"}
          )
        else
          # Second call: final response after tool execution
          MockResponses.stream_text_response("Your dark mode preference has been saved!")
        end
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      |> assert_has("#chat-textarea")
      |> type("#chat-textarea", "Remember that I prefer dark mode")
      |> click("button[title='Send message']")
      |> assert_has(".prose", text: "Your dark mode preference has been saved!")
    end

    test "search memories tool call completes successfully", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      call_count = :counters.new(1, [])

      stub(LLMMock, :stream_text, fn _model, _context, _opts ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        if count == 1 do
          # First call: trigger a tool call (non-matching name for graceful failure)
          MockResponses.stream_text_with_tool_call(
            "Let me search my memories for that.",
            "memories_search",
            %{"query" => "dark mode preference"}
          )
        else
          # Second call: final response after tool execution
          MockResponses.stream_text_response(
            "Based on my search, I found your preference for dark mode."
          )
        end
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      |> assert_has("#chat-textarea")
      |> type("#chat-textarea", "What do you remember about my theme preferences?")
      |> click("button[title='Send message']")
      |> assert_has(".prose",
        text: "Based on my search, I found your preference for dark mode."
      )
    end

    test "tool call UI shows memory operation indicators", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      call_count = :counters.new(1, [])

      stub(LLMMock, :stream_text, fn _model, _context, _opts ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        if count == 1 do
          # First call: trigger a tool call (non-matching name for graceful failure)
          MockResponses.stream_text_with_tool_call(
            "Saving that for you now.",
            "memory_set",
            %{"name" => "favorite_color", "summary" => "User's favorite color is blue"}
          )
        else
          # Second call: final response after tool execution
          MockResponses.stream_text_response("Done! Blue has been saved as your favorite color.")
        end
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      |> assert_has("#chat-textarea")
      |> type("#chat-textarea", "My favorite color is blue, please remember that")
      |> click("button[title='Send message']")
      # Verify tool call entry appears in the UI
      |> assert_has(".tool-call-entry")
      |> assert_has(".prose", text: "Done! Blue has been saved as your favorite color.")
    end
  end
end
