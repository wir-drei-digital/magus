defmodule Magus.Agents.Tools.Memory.SearchMemories do
  @moduledoc """
  Tool for semantic search across memories.

  Uses vector embeddings to find memories most relevant to a search query.
  Can search local, global, or all memories.

  ## Usage with Jido AI

      tools = [Magus.Agents.Tools.Memory.SearchMemories]
      tool_contexts = %{
        Magus.Agents.Tools.Memory.SearchMemories => %{
          conversation_id: conversation.id,
          user_id: user.id
        }
      }
  """

  use Jido.Action,
    name: "search_memories",
    description: """
    Semantic search across memories by their summaries.
    Returns memories most relevant to your query.

    SCOPE determines which memories to search:
    - "local" (default): Only memories in this conversation.
    - "user": Only user-level memories available across all conversations.
    - "agent": Only memories scoped to a specific custom agent.
    - "all": Both local and global memories.

    Use this when you need to find specific information across multiple memories.
    Searches your curated conversation and user memories, not cross-source claims.
    """,
    schema: [
      query: [
        type: :string,
        required: true,
        doc: "Search query to find relevant memories"
      ],
      limit: [
        type: :integer,
        required: false,
        default: 5,
        doc: "Maximum number of results to return"
      ],
      scope: [
        type: :string,
        required: false,
        default: "local",
        doc: "Memory scope: 'local', 'global', 'agent', or 'all'"
      ],
      kind: [
        type: {:or, [:string, nil]},
        default: nil,
        doc:
          "Filter by memory kind: general, fact, hypothesis, observation, summary, preference, goal, topic, habit, reflection"
      ]
    ]

  require Logger

  alias Magus.Files.EmbeddingModel

  import Magus.Agents.Tools.Memory.Helpers,
    only: [
      validate_context: 2,
      format_datetime: 1,
      ai_actor: 0,
      validate_list_scope: 1,
      enforce_global_read_isolation: 2,
      resolve_user_bucket: 1,
      bucket_error_message: 1
    ]

  import Magus.Agents.Tools.Helpers, only: [get_param: 2, get_param: 3]

  @doc "User-friendly display name shown in the UI when this tool is executing"
  def display_name, do: "Searching memories..."

  @doc "Generate a human-readable summary of the tool output for UI display"
  def summarize_output(%{count: 0}), do: "No matches"
  def summarize_output(%{count: count}), do: "Found #{count} matches"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    scope = get_param(params, :scope, "local")

    with {:ok, scope} <- validate_list_scope(scope),
         {:ok, scope} <- enforce_global_read_isolation(scope, context) do
      required_fields =
        case scope do
          "user" -> [:user_id]
          "agent" -> [:custom_agent_id]
          "all" -> [:conversation_id, :user_id]
          _ -> [:conversation_id]
        end

      with {:ok, ctx} <- validate_context(context, required_fields),
           {:ok, ctx} <- put_user_bucket(ctx, context, scope) do
        query = get_param(params, :query)
        limit = get_param(params, :limit, 5)

        Logger.debug("SearchMemories: executing",
          query: query,
          scope: scope,
          conversation_id: Map.get(ctx, :conversation_id),
          user_id: Map.get(ctx, :user_id)
        )

        kind = get_param(params, :kind)
        search_memories(query, limit, scope, ctx, kind)
      else
        {:error, message} -> {:ok, %{error: message}}
      end
    else
      {:error, message} -> {:ok, %{error: message}}
    end
  end

  # For "user" and "all" scopes (both read a user-memory bucket), resolve the
  # workspace bucket from the conversation (the tool context value is only a
  # fallback) and pin it into ctx so the search uses the same bucket.
  # Resolution reads from the original tool context, since validate_context/2
  # strips ctx down to only the scope's required_fields.
  defp put_user_bucket(ctx, context, scope) when scope in ["user", "all"] do
    case resolve_user_bucket(context) do
      {:ok, workspace_id} -> {:ok, Map.put(ctx, :workspace_id, workspace_id)}
      {:error, reason} -> {:error, bucket_error_message(reason)}
    end
  end

  defp put_user_bucket(ctx, _context, _scope), do: {:ok, ctx}

  defp search_memories(query, limit, scope, ctx, kind) do
    case EmbeddingModel.embed(query) do
      {:ok, embedding} ->
        search_with_embedding(query, embedding, limit, scope, ctx, kind)

      {:error, reason} ->
        Logger.error("SearchMemories: embedding failed - #{inspect(reason)}")
        {:ok, %{error: "Search failed: #{inspect(reason)}"}}
    end
  end

  defp search_with_embedding(query, embedding, limit, "user", ctx, kind) do
    workspace_id = Map.get(ctx, :workspace_id)

    case Magus.Memory.search_user_memories(ctx.user_id, workspace_id, embedding, %{limit: limit},
           actor: ai_actor()
         ) do
      {:ok, memories} ->
        touch_memory_ids(memories)
        results = memories |> filter_by_kind(kind) |> Enum.map(&format_result(&1, "user"))

        {:ok,
         %{
           query: query,
           scope: "user",
           count: length(results),
           results: results
         }}

      {:error, error} ->
        Logger.error("SearchMemories: search failed - #{inspect(error)}")
        {:ok, %{error: "Search failed: #{inspect(error)}"}}
    end
  end

  defp search_with_embedding(query, embedding, limit, "all", ctx, kind) do
    # Search both scopes and combine results
    local_limit = div(limit + 1, 2)
    global_limit = div(limit, 2) + 1

    local_results =
      case Magus.Memory.search_memories(ctx.conversation_id, embedding, %{limit: local_limit},
             actor: ai_actor()
           ) do
        {:ok, memories} ->
          touch_memory_ids(memories)
          memories |> filter_by_kind(kind) |> Enum.map(&format_result(&1, "local"))

        {:error, _} ->
          []
      end

    workspace_id = Map.get(ctx, :workspace_id)

    global_results =
      case Magus.Memory.search_user_memories(
             ctx.user_id,
             workspace_id,
             embedding,
             %{limit: global_limit},
             actor: ai_actor()
           ) do
        {:ok, memories} ->
          touch_memory_ids(memories)
          memories |> filter_by_kind(kind) |> Enum.map(&format_result(&1, "user"))

        {:error, _} ->
          []
      end

    # Combine and limit total results
    all_results = Enum.take(local_results ++ global_results, limit)

    {:ok,
     %{
       query: query,
       scope: "all",
       count: length(all_results),
       results: all_results
     }}
  end

  defp search_with_embedding(query, embedding, limit, "agent", ctx, kind) do
    case Magus.Memory.search_agent_memories(ctx.custom_agent_id, embedding, %{limit: limit},
           actor: ai_actor()
         ) do
      {:ok, memories} ->
        touch_memory_ids(memories)
        results = memories |> filter_by_kind(kind) |> Enum.map(&format_result(&1, "agent"))

        {:ok,
         %{
           query: query,
           scope: "agent",
           count: length(results),
           results: results
         }}

      {:error, error} ->
        Logger.error("SearchMemories: agent search failed - #{inspect(error)}")
        {:ok, %{error: "Search failed: #{inspect(error)}"}}
    end
  end

  defp search_with_embedding(query, embedding, limit, _scope, ctx, kind) do
    case Magus.Memory.search_memories(ctx.conversation_id, embedding, %{limit: limit},
           actor: ai_actor()
         ) do
      {:ok, memories} ->
        touch_memory_ids(memories)
        results = memories |> filter_by_kind(kind) |> Enum.map(&format_result(&1, "local"))

        {:ok,
         %{
           query: query,
           scope: "local",
           count: length(results),
           results: results
         }}

      {:error, error} ->
        Logger.error("SearchMemories: search failed - #{inspect(error)}")
        {:ok, %{error: "Search failed: #{inspect(error)}"}}
    end
  end

  defp format_result(memory, scope) do
    %{
      name: memory.name,
      summary: memory.summary,
      scope: scope,
      kind: to_string(memory.kind),
      confidence: memory.confidence,
      updated_at: format_datetime(memory.updated_at)
    }
  end

  @valid_kinds ~w(general fact hypothesis observation summary preference goal topic habit reflection)

  defp filter_by_kind(memories, nil), do: memories

  defp filter_by_kind(memories, kind) when kind in @valid_kinds do
    kind_atom = String.to_existing_atom(kind)
    Enum.filter(memories, &(&1.kind == kind_atom))
  end

  defp filter_by_kind(memories, _invalid_kind), do: memories

  defp touch_memory_ids(memories) do
    Enum.map(memories, & &1.id) |> Magus.Memory.touch_accessed()
  rescue
    _ -> :ok
  end
end
