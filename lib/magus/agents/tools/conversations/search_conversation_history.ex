defmodule Magus.Agents.Tools.Conversations.SearchConversationHistory do
  @moduledoc """
  Tool for searching through messages in the current conversation.

  Uses PostgreSQL full-text search (tsvector + trigram similarity) to find
  messages matching the search query within the conversation context.

  ## Usage with Jido AI

      tools = [Magus.Agents.Tools.Conversations.SearchConversationHistory]
      tool_contexts = %{
        Magus.Agents.Tools.Conversations.SearchConversationHistory => %{
          conversation_id: conversation.id
        }
      }
  """

  use Jido.Action,
    name: "search_conversation_history",
    description: """
    Search through previous messages in this conversation using text search.
    Use this to find specific information or context from earlier in the conversation.
    Returns messages matching the search query, sorted by most recent first.
    """,
    schema: [
      query: [
        type: :string,
        required: true,
        doc: "Search query to find relevant messages"
      ],
      limit: [
        type: :integer,
        required: false,
        default: 10,
        doc: "Maximum number of results to return (1-50)"
      ]
    ]

  require Logger

  import Magus.Agents.Tools.Conversations.Helpers,
    only: [validate_context: 2, format_message: 1, ai_actor: 0]

  import Magus.Agents.Tools.Helpers, only: [get_param: 2, get_param: 3]

  @max_limit 50

  @doc "User-friendly display name shown in the UI when this tool is executing"
  def display_name, do: "Searching conversation history..."

  @doc "Generate a human-readable summary of the tool output for UI display"
  def summarize_output(%{count: 0}), do: "No matches"
  def summarize_output(%{count: count}), do: "Found #{count} messages"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id]) do
      {:ok, ctx} ->
        query = get_param(params, :query)
        limit = get_param(params, :limit, 10)

        Logger.debug("SearchConversationHistory: executing",
          query: query,
          conversation_id: ctx.conversation_id
        )

        search_messages(query, limit, ctx.conversation_id)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp search_messages(query, limit, conversation_id) do
    # Clamp limit between 1 and max (Ash pagination requires positive integers)
    limit = max(1, min(limit, @max_limit))

    if is_nil(query) or query == "" do
      {:ok, %{error: "Search query is required"}}
    else
      case Magus.Chat.search_messages_in_conversation(conversation_id, query,
             page: [limit: limit],
             actor: ai_actor()
           ) do
        {:ok, page} ->
          messages = Enum.map(page.results, &format_message/1)

          {:ok,
           %{
             query: query,
             count: length(messages),
             messages: messages
           }}

        {:error, error} ->
          Logger.error("SearchConversationHistory: search failed - #{inspect(error)}")
          {:ok, %{error: "Search failed: #{inspect(error)}"}}
      end
    end
  end
end
