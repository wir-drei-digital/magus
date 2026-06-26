defmodule Magus.Agents.Tools.Conversations.FetchConversationHistory do
  @moduledoc """
  Tool for fetching paginated messages from the current conversation.

  Returns messages in reverse chronological order (newest first) with support
  for cursor-based pagination using message IDs.

  ## Usage with Jido AI

      tools = [Magus.Agents.Tools.Conversations.FetchConversationHistory]
      tool_contexts = %{
        Magus.Agents.Tools.Conversations.FetchConversationHistory => %{
          conversation_id: conversation.id
        }
      }
  """

  use Jido.Action,
    name: "fetch_conversation_history",
    description: """
    Fetch previous messages from this conversation with pagination.
    Use this to review the conversation history or recall earlier context.
    Messages are returned in reverse chronological order (newest first).
    Use before_id to fetch older messages (pagination).
    """,
    schema: [
      limit: [
        type: :integer,
        required: false,
        default: 20,
        doc: "Number of messages to fetch (1-50)"
      ],
      before_id: [
        type: :string,
        required: false,
        doc: "Fetch messages before this message ID (for pagination)"
      ]
    ]

  require Logger
  require Ash.Query

  import Magus.Agents.Tools.Conversations.Helpers,
    only: [validate_context: 2, format_message: 1, ai_actor: 0]

  import Magus.Agents.Tools.Helpers, only: [get_param: 3]

  @max_limit 50

  @doc "User-friendly display name shown in the UI when this tool is executing"
  def display_name, do: "Fetching conversation history..."

  @doc "Generate a human-readable summary of the tool output for UI display"
  def summarize_output(%{count: 0}), do: "No messages"
  def summarize_output(%{count: count}), do: "Fetched #{count} messages"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id]) do
      {:ok, ctx} ->
        limit = get_param(params, :limit, 20)
        before_id = get_param(params, :before_id, nil)

        Logger.debug("FetchConversationHistory: executing",
          conversation_id: ctx.conversation_id,
          limit: limit,
          before_id: before_id
        )

        fetch_messages(limit, before_id, ctx.conversation_id)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp fetch_messages(limit, before_id, conversation_id) do
    # Clamp limit between 1 and max (Ash pagination requires positive integers)
    limit = max(1, min(limit, @max_limit))

    # Build the base query
    query =
      Magus.Chat.Message
      |> Ash.Query.for_read(:for_conversation, %{conversation_id: conversation_id})
      |> Ash.Query.filter(message_type == :message)
      |> Ash.Query.filter(disabled != true)

    # Add before_id filter if provided (for pagination)
    query =
      if before_id do
        # Get the timestamp of the before_id message for cursor-based pagination
        case get_message_timestamp(before_id) do
          {:ok, timestamp} ->
            Ash.Query.filter(query, inserted_at < ^timestamp)

          :error ->
            query
        end
      else
        query
      end

    # Execute with limit + 1 to check for more results
    case Ash.read(query, page: [limit: limit + 1], actor: ai_actor()) do
      {:ok, page} ->
        all_results = page.results
        has_more = length(all_results) > limit
        messages = all_results |> Enum.take(limit) |> Enum.map(&format_message/1)

        {:ok,
         %{
           count: length(messages),
           messages: messages,
           has_more: has_more
         }}

      {:error, error} ->
        Logger.error("FetchConversationHistory: fetch failed - #{inspect(error)}")
        {:ok, %{error: "Failed to fetch messages: #{inspect(error)}"}}
    end
  end

  defp get_message_timestamp(message_id) do
    case Magus.Chat.get_message(message_id, actor: ai_actor()) do
      {:ok, message} -> {:ok, message.inserted_at}
      _ -> :error
    end
  end
end
