defmodule Magus.Chat.Conversation.Actions.SummarizeWindowTest do
  @moduledoc """
  Tests for the conversation-window summarizer.
  """
  use Magus.ResourceCase, async: true

  import Mox

  alias Magus.Chat.Conversation.Actions.SummarizeWindow
  alias Magus.Test.Mocks.LLMMock
  alias Magus.Test.MockResponses

  setup :verify_on_exit!

  describe "summarize/2" do
    test "returns the LLM summary for a window of messages" do
      expect(LLMMock, :generate_text, fn _model, _context, _opts ->
        MockResponses.generate_text_response("the stubbed summary")
      end)

      messages = [
        %{role: :user, text: "Let's plan the launch for Friday."},
        %{role: :agent, text: "Sure, I'll draft the checklist."}
      ]

      assert {:ok, "the stubbed summary"} = SummarizeWindow.summarize(messages)
    end

    test "builds a role-prefixed transcript and sends it as a single user message" do
      expect(LLMMock, :generate_text, fn _model, context, _opts ->
        transcript = user_transcript(context)

        assert transcript =~ "User: How do I make sourdough?"
        assert transcript =~ "Assistant: Use a starter."

        MockResponses.generate_text_response("summary")
      end)

      messages = [
        %{role: :user, text: "How do I make sourdough?"},
        %{role: :agent, text: "Use a starter."}
      ]

      assert {:ok, "summary"} = SummarizeWindow.summarize(messages)
    end

    test "returns {:ok, \"\"} for an empty message list without calling the LLM" do
      # No expect/3 set up: a call to the LLM would fail verify_on_exit!.
      assert {:ok, ""} = SummarizeWindow.summarize([])
    end

    test "honors a model override" do
      expect(LLMMock, :generate_text, fn model, _context, _opts ->
        assert model == "openrouter:test/cheap-model"
        MockResponses.generate_text_response("summary")
      end)

      messages = [%{role: :user, text: "hello"}]

      assert {:ok, "summary"} =
               SummarizeWindow.summarize(messages, model: "openrouter:test/cheap-model")
    end

    test "coalesces a nil-message response to {:ok, \"\"} instead of {:ok, nil}" do
      # ReqLLM.Response.text/1 returns nil for a message-less response. summarize/2
      # must coalesce that to "" so the compaction worker's {:ok, ""} no-op branch
      # handles it instead of raising CaseClauseError on {:ok, nil}.
      expect(LLMMock, :generate_text, fn _model, _context, _opts ->
        MockResponses.generate_text_nil_response()
      end)

      messages = [%{role: :user, text: "hello"}]

      assert {:ok, ""} = SummarizeWindow.summarize(messages)
    end

    test "returns {:error, reason} on LLM failure without raising" do
      expect(LLMMock, :generate_text, fn _model, _context, _opts ->
        {:error, :rate_limited}
      end)

      messages = [%{role: :user, text: "hello"}]

      assert {:error, :rate_limited} = SummarizeWindow.summarize(messages)
    end

    test "accepts string-keyed maps" do
      expect(LLMMock, :generate_text, fn _model, context, _opts ->
        assert user_transcript(context) =~ "User: hi there"
        MockResponses.generate_text_response("summary")
      end)

      messages = [%{"role" => "user", "text" => "hi there"}]

      assert {:ok, "summary"} = SummarizeWindow.summarize(messages)
    end
  end

  # Extract the text of the user-role messages from a ReqLLM.Context,
  # mirroring how ReqLLM.Response.text/1 reads :text content parts.
  defp user_transcript(context) do
    context.messages
    |> Enum.filter(&(&1.role == :user))
    |> Enum.map_join("\n", fn message ->
      message.content
      |> Enum.filter(&(&1.type == :text))
      |> Enum.map_join("", & &1.text)
    end)
  end
end
