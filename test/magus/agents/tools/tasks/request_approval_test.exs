defmodule Magus.Agents.Tools.Tasks.RequestApprovalTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Tasks.RequestApproval

  describe "display_name/0" do
    test "returns display name" do
      assert RequestApproval.display_name() == "Requesting approval..."
    end
  end

  describe "summarize_output/1" do
    test "summarizes pending approval" do
      assert RequestApproval.summarize_output(%{status: "pending", question: "Create PR?"}) ==
               "Waiting for approval: Create PR?"
    end

    test "summarizes error" do
      assert RequestApproval.summarize_output(%{error: "missing context"}) ==
               "Error: missing context"
    end

    test "falls back for unknown shape" do
      assert RequestApproval.summarize_output(%{}) == "Approval requested"
    end
  end

  describe "run/2" do
    setup do
      user = generate(user())
      {:ok, conversation} = Magus.Chat.create_conversation(%{}, actor: user)

      context = %{
        user_id: user.id,
        conversation_id: conversation.id
      }

      %{user: user, conversation: conversation, context: context}
    end

    test "creates notification and returns action cards", %{context: context, user: user} do
      params = %{
        "question" => "Create PR for auth fix?",
        "options" => ["Approve", "Reject", "Review first"],
        "context" => "Branch: fix/auth-789"
      }

      {:ok, result} = RequestApproval.run(params, context)

      assert result.status == "pending"
      assert result.question == "Create PR for auth fix?"
      assert result.options == ["Approve", "Reject", "Review first"]
      assert result.hint =~ "MUST stop here"

      # Verify action cards structure
      assert result.action_cards["layout"] == "list"
      assert length(result.action_cards["cards"]) == 3
      first_card = hd(result.action_cards["cards"])
      assert first_card["title"] == "Approve"
      assert first_card["action"]["type"] == "send_message"
      assert first_card["action"]["payload"] =~ "Approve"
      assert first_card["action"]["payload"] =~ "Create PR for auth fix?"

      # Verify notification was created
      {:ok, notifications} = Magus.Notifications.list_unread_notifications(actor: user)
      approval = Enum.find(notifications, &(&1.notification_type == :approval_request))
      assert approval != nil
      assert approval.body == "Create PR for auth fix?"
      assert approval.title == "Approval needed"
      assert approval.target_conversation_id == context.conversation_id
    end

    test "uses default options when not specified", %{context: context} do
      {:ok, result} = RequestApproval.run(%{"question" => "Proceed?"}, context)
      assert result.options == ["Approve", "Reject"]
      assert length(result.action_cards["cards"]) == 2
    end

    test "returns error when context is missing" do
      {:ok, result} = RequestApproval.run(%{"question" => "Test?"}, %{})
      assert result.error
    end
  end
end
