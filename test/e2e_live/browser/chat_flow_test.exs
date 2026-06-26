defmodule Magus.LiveE2E.Browser.ChatFlowTest do
  @moduledoc """
  Browser-based E2E tests with real LLM responses.
  Verifies the complete user experience from typing to seeing AI output.
  """
  use Magus.LiveE2EBrowserCase

  @moduletag :e2e_browser

  describe "live chat in browser" do
    test "user sends message and sees real AI response", %{conn: conn, user: user, model: model} do
      conversation = create_conversation(user, model)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      |> assert_has("#chat-textarea")
      |> type("#chat-textarea", "Say hello in one short sentence.")
      |> click("button[title='Send message']")
      # Wait for real LLM response to appear (longer timeout than mocked tests)
      |> assert_has(".prose", timeout: 60_000)
    end
  end
end
