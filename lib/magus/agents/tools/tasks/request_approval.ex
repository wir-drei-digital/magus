defmodule Magus.Agents.Tools.Tasks.RequestApproval do
  use Jido.Action,
    name: "request_approval",
    description: """
    Ask the user for approval before proceeding with a high-stakes action. After calling this,
    you MUST stop and wait — save any context you need to agent memory so you can resume when
    the user responds.
    """,
    schema: [
      question: [type: :string, required: true, doc: "What you're asking approval for"],
      options: [
        type: {:list, :string},
        default: ["Approve", "Reject"],
        doc: "Response options for the user"
      ],
      context: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Additional context about what will happen"
      ]
    ]

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2]

  require Logger

  def display_name, do: "Requesting approval..."

  def summarize_output(%{status: "pending", question: q}), do: "Waiting for approval: #{q}"
  def summarize_output(%{error: e}), do: "Error: #{e}"
  def summarize_output(_), do: "Approval requested"

  @impl true
  def run(params, context) do
    case validate_context(context, [:user_id, :conversation_id]) do
      {:ok, ctx} ->
        question = params["question"]
        options = params["options"] || ["Approve", "Reject"]
        extra_context = params["context"]

        # Create notification to alert user
        case Magus.Notifications.create_notification(
               %{
                 user_id: ctx.user_id,
                 notification_type: :approval_request,
                 title: "Approval needed",
                 body: question,
                 target_conversation_id: ctx.conversation_id,
                 metadata: %{options: options, context: extra_context}
               },
               authorize?: false
             ) do
          {:ok, _notification} ->
            # Create :waiting inbox event for custom agent conversations
            create_approval_inbox_event(ctx, question, options, extra_context)

            # Build action cards for the message
            cards =
              Enum.map(options, fn option ->
                %{
                  "title" => option,
                  "action" => %{
                    "type" => "send_message",
                    "payload" => "#{option}: #{question}"
                  }
                }
              end)

            {:ok,
             %{
               status: "pending",
               question: question,
               options: options,
               action_cards: %{"layout" => "list", "cards" => cards},
               hint:
                 "IMPORTANT: You MUST stop here and wait for the user's response. Do NOT proceed with the action. Save any context you need to agent memory (set_memory with scope 'agent') so you can resume when the user responds to your approval request."
             }}

          {:error, reason} ->
            {:ok, %{error: "Failed to send approval notification: #{inspect(reason)}"}}
        end

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp create_approval_inbox_event(ctx, question, options, extra_context) do
    case Magus.Chat.get_conversation(ctx.conversation_id, authorize?: false) do
      {:ok, conversation} when not is_nil(conversation.custom_agent_id) ->
        user = Magus.Accounts.get_user!(ctx.user_id, authorize?: false)

        Magus.Agents.create_waiting_inbox_event(
          %{
            agent_id: conversation.custom_agent_id,
            event_type: :approval_response,
            urgency: :immediate,
            title: "Approval needed: #{question}",
            summary: extra_context,
            source_type: :conversation,
            source_id: ctx.conversation_id,
            payload: %{
              question: question,
              options: options,
              conversation_id: ctx.conversation_id,
              context: extra_context
            },
            idempotency_key: "approval:#{ctx.conversation_id}:#{:erlang.phash2(question)}"
          },
          actor: user
        )

      _ ->
        # Regular conversation or not found — skip
        :ok
    end
  rescue
    e ->
      Logger.warning("RequestApproval: inbox event creation failed: #{inspect(e)}")
  end
end
