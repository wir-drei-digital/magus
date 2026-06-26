defmodule Magus.Agents.Tools.Tasks.RequestApprovalInboxTest do
  @moduledoc """
  Tests that RequestApproval creates a :waiting AgentInboxEvent when the
  conversation is associated with a custom agent.
  """

  use Magus.ResourceCase, async: true

  import Magus.Generators

  require Ash.Query

  alias Magus.Agents.AgentInboxEvent
  alias Magus.Agents.Tools.Tasks.RequestApproval

  defp inbox_events_for_agent(agent_id) do
    AgentInboxEvent
    |> Ash.Query.filter(agent_id == ^agent_id)
    |> Ash.read!(authorize?: false)
  end

  describe "inbox event creation on approval request" do
    test "creates a :waiting inbox event when conversation has a custom_agent_id" do
      user = generate(user())
      agent = custom_agent(user)

      {:ok, conversation} =
        Magus.Chat.create_conversation(%{custom_agent_id: agent.id}, actor: user)

      context = %{user_id: user.id, conversation_id: conversation.id}
      params = %{"question" => "Deploy to production?", "options" => ["Approve", "Reject"]}

      {:ok, result} = RequestApproval.run(params, context)

      assert result.status == "pending"

      events = inbox_events_for_agent(agent.id)
      assert length(events) == 1

      event = hd(events)
      assert event.status == :waiting
      assert event.event_type == :approval_response
      assert event.urgency == :immediate
      assert event.source_type == :conversation
      assert event.source_id == conversation.id
      assert event.payload["question"] == "Deploy to production?"
      assert event.payload["options"] == ["Approve", "Reject"]
      assert event.payload["conversation_id"] == conversation.id
    end

    test "does not create an inbox event for a regular conversation without custom_agent_id" do
      user = generate(user())
      agent = custom_agent(user)

      # Conversation with no custom_agent_id
      {:ok, conversation} = Magus.Chat.create_conversation(%{}, actor: user)

      context = %{user_id: user.id, conversation_id: conversation.id}
      params = %{"question" => "Proceed?", "options" => ["Yes", "No"]}

      {:ok, result} = RequestApproval.run(params, context)

      assert result.status == "pending"
      assert inbox_events_for_agent(agent.id) == []
    end

    test "inbox event payload includes context when provided" do
      user = generate(user())
      agent = custom_agent(user)

      {:ok, conversation} =
        Magus.Chat.create_conversation(%{custom_agent_id: agent.id}, actor: user)

      context = %{user_id: user.id, conversation_id: conversation.id}

      params = %{
        "question" => "Send email?",
        "options" => ["Send", "Cancel"],
        "context" => "Will notify 500 users"
      }

      {:ok, _result} = RequestApproval.run(params, context)

      event = inbox_events_for_agent(agent.id) |> hd()
      assert event.payload["context"] == "Will notify 500 users"
    end

    test "idempotency key is stable for the same question in the same conversation" do
      user = generate(user())
      agent = custom_agent(user)

      {:ok, conversation} =
        Magus.Chat.create_conversation(%{custom_agent_id: agent.id}, actor: user)

      context = %{user_id: user.id, conversation_id: conversation.id}
      params = %{"question" => "Delete records?", "options" => ["Approve", "Reject"]}

      # First call
      {:ok, _} = RequestApproval.run(params, context)
      # Second call with same question — idempotency key matches, no duplicate
      {:ok, _} = RequestApproval.run(params, context)

      assert length(inbox_events_for_agent(agent.id)) == 1
    end
  end
end
