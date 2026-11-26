defmodule Magus.LiveE2E.Browser.ChatFlowTest do
  @moduledoc """
  Browser-based E2E tests with real LLM responses.
  Verifies the complete user experience from typing to seeing AI output.
  """
  use Magus.LiveE2EBrowserCase

  import Fluffy.Locator, only: [by_css: 1, first: 1]

  @moduletag :e2e_browser

  describe "live chat in browser" do
    test "user sends message and sees real AI response", %{
      session: session,
      user: user,
      model: model
    } do
      conversation = create_conversation(user, model)
      chat_input = by_css("#chat-textarea")

      session
      |> authenticate(user)
      |> Fluffy.visit(~p"/chat/#{conversation.id}")
      |> assert_has(chat_input)
      |> Fluffy.Playwright.press_sequentially(chat_input, "Say hello in one short sentence.")
      |> Fluffy.click(by_css("button[title='Send message']"))
      # Wait for real LLM response to appear (longer timeout than mocked tests)
      |> assert_has(first(by_css(".prose")), timeout: 60_000)
    end
  end
end
