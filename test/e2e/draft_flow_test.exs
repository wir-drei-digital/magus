defmodule MagusWeb.E2E.DraftFlowTest do
  @moduledoc """
  Browser-based E2E tests for the draft creation and pane interaction flow.

  These tests use Playwright to drive a real browser and verify that:
  - The write_draft tool creates a draft document
  - The draft pane opens automatically with the correct content
  - Multiple tool call iterations (write + read) work correctly

  All LLM calls are mocked -- no API keys needed.
  """
  use MagusWeb.PlaywrightCase

  @moduletag :e2e

  describe "draft creation" do
    test "write_draft tool creates and opens draft pane", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      call_count = :counters.new(1, [])

      stub(LLMMock, :stream_text, fn _model, _context, _opts ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        if count == 1 do
          MockResponses.stream_text_with_tool_call(
            "Creating a draft for you now.",
            "draft_write",
            %{"title" => "Meeting Notes", "content" => "Meeting notes content"}
          )
        else
          MockResponses.stream_text_response(
            "Your draft with the meeting notes has been created!"
          )
        end
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      |> assert_has("#chat-textarea")
      |> type("#chat-textarea", "Create meeting notes for today")
      |> click("button[title='Send message']")
      |> assert_has(".tool-call-entry", timeout: 10_000)
      |> assert_has(".prose",
        text: "Your draft with the meeting notes has been created!",
        timeout: 10_000
      )
    end

    test "draft pane shows title and content after creation", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      call_count = :counters.new(1, [])

      stub(LLMMock, :stream_text, fn _model, _context, _opts ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        if count == 1 do
          MockResponses.stream_text_with_tool_call(
            "Creating the project proposal now.",
            "draft_write",
            %{"title" => "Project Proposal", "content" => "Proposal content"}
          )
        else
          MockResponses.stream_text_response(
            "The project proposal draft has been created and is ready for review."
          )
        end
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      |> assert_has("#chat-textarea")
      |> type("#chat-textarea", "Write a project proposal")
      |> click("button[title='Send message']")
      |> assert_has(".tool-call-entry", timeout: 10_000)
      |> assert_has(".prose",
        text: "The project proposal draft has been created and is ready for review.",
        timeout: 10_000
      )
    end

    test "AI creates draft then reads it back in multiple iterations", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      call_count = :counters.new(1, [])

      stub(LLMMock, :stream_text, fn _model, _context, _opts ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        case count do
          1 ->
            # First call: write the draft (non-matching name for graceful failure)
            MockResponses.stream_text_with_tool_call(
              "Creating the technical spec now.",
              "draft_write",
              %{"title" => "Technical Spec", "content" => "Spec content"}
            )

          2 ->
            # Second call: read the draft back (non-matching name)
            MockResponses.stream_text_with_tool_call(
              "Now reading the draft to verify the content.",
              "draft_read",
              %{}
            )

          _ ->
            # Third call: final response
            MockResponses.stream_text_response(
              "The technical spec draft has been created and verified successfully."
            )
        end
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      |> assert_has("#chat-textarea")
      |> type("#chat-textarea", "Create and verify a technical spec")
      |> click("button[title='Send message']")
      |> assert_has(".tool-call-entry", timeout: 10_000)
      |> assert_has(".prose",
        text: "The technical spec draft has been created and verified successfully.",
        timeout: 10_000
      )
    end
  end
end
