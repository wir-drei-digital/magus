defmodule Magus.Agents.Plugins.Support.ErrorMessagesTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Agents.Plugins.Support.ErrorMessages

  describe "format_user_friendly_error/2" do
    test "limit_exceeded formats a PolicyError via the web formatter" do
      error =
        Magus.Usage.PolicyError.exception(
          limit_type: :spend_cap,
          current: 2000,
          limit: 2000,
          upgrade_path: "pro"
        )

      assert ErrorMessages.format_user_friendly_error(:limit_exceeded, error) =~
               "monthly spend cap"
    end

    test "limit_exceeded passes through binary error" do
      assert ErrorMessages.format_user_friendly_error(:limit_exceeded, "Spend cap reached") ==
               "Spend cap reached"
    end

    test "request_failed with timeout returns timeout message" do
      assert ErrorMessages.format_user_friendly_error(
               :request_failed,
               {:react_worker_exit, {:timeout, :gen_server}}
             ) =~ "timed out"
    end

    test "request_failed with HTTP 502 returns unavailable message" do
      assert ErrorMessages.format_user_friendly_error(
               :request_failed,
               {:react_worker_exit, %{status: 502}}
             ) =~ "temporarily unavailable"
    end

    test "request_failed with HTTP 503 returns unavailable message" do
      assert ErrorMessages.format_user_friendly_error(
               :request_failed,
               {:react_worker_exit, %{status: 503}}
             ) =~ "temporarily unavailable"
    end

    test "request_failed with unknown error returns generic message" do
      assert ErrorMessages.format_user_friendly_error(:request_failed, :something_else) =~
               "Something went wrong"
    end

    test "busy returns busy message" do
      assert ErrorMessages.format_user_friendly_error(:busy, "Agent is busy") =~
               "still processing"
    end

    test "unknown error type returns generic message" do
      assert ErrorMessages.format_user_friendly_error(:unknown, "wat") =~
               "unexpected error"
    end
  end

  describe "create_error_event/3" do
    test "creates a persisted event message in the conversation" do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      ErrorMessages.create_error_event(conversation.id, :request_failed, :some_error)

      require Ash.Query

      messages =
        Magus.Chat.Message
        |> Ash.Query.filter(conversation_id == ^conversation.id and message_type == :event)
        |> Ash.read!(authorize?: false)

      assert length(messages) == 1
      assert hd(messages).text =~ "Something went wrong"
      assert hd(messages).complete == true
    end

    test "does not crash on invalid conversation_id" do
      # Should rescue and log, not crash
      assert ErrorMessages.create_error_event("nonexistent-uuid", :request_failed, :error) ==
               nil
    end
  end
end
