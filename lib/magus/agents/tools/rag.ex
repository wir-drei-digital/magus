defmodule Magus.Agents.Tools.Rag do
  @moduledoc """
  RAG (Retrieval-Augmented Generation) tool for semantic search.

  Allows agents to search through user-uploaded documents. The tool accepts
  a query string and returns relevant document passages with source citations.

  File IDs are resolved lazily at query time from the tool context fields:
  `user_id`, `conversation_id`, `folder_id`, `workspace_id`,
  `can_access_global_files`, `can_access_knowledge`, and `custom_agent_id`.
  """

  use Jido.Action,
    name: "search_files",
    description: """
    Search the user's uploaded documents and files for relevant information.
    Use this tool when the user asks questions that might be answered by their uploaded documents,
    or when you need to find specific information from PDFs, text files, or other uploaded content.
    Always cite the source document when using information from this tool.
    Searches raw document excerpts (verbatim file text), not distilled facts.
    """,
    schema: [
      query: [
        type: :string,
        required: true,
        doc: "The search query to find relevant document passages"
      ],
      limit: [
        type: :integer,
        default: 5,
        doc: "Maximum number of results to return (default: 5)"
      ]
    ]

  require Logger

  alias Magus.Files.EmbeddingModel

  @doc "User-friendly display name shown in the UI when this tool is executing"
  def display_name, do: "Searching files..."

  @doc "Generate a human-readable summary of the tool output for UI display"
  def summarize_output(%{num_results: count}), do: "Found #{count} results"
  def summarize_output(%{results: [], message: _}), do: "No documents available"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Search completed"

  import Magus.Agents.Tools.Helpers, only: [get_param: 2, get_param: 3]

  @impl true
  def run(params, context) when is_map(context) do
    query = get_param(params, :query)
    limit = get_param(params, :limit, 5)
    actor = Map.get(context, :user)

    cond do
      !is_binary(query) or query == "" ->
        {:ok,
         %{
           results: [],
           message: "No search query provided."
         }}

      not is_struct(actor, Magus.Accounts.User) ->
        Logger.warning("RAG tool invoked without a user actor in context; returning no results")

        {:ok,
         %{
           results: [],
           message: "No documents available."
         }}

      true ->
        all_file_ids = resolve_file_ids(context, actor)

        Logger.info("RAG tool executing",
          query: query,
          total_file_ids: length(all_file_ids)
        )

        if all_file_ids == [] do
          {:ok,
           %{
             results: [],
             message: "No documents available. The user hasn't uploaded any files."
           }}
        else
          case EmbeddingModel.embed_query(query) do
            {:ok, embedding} ->
              search_and_format(embedding, all_file_ids, limit, query, actor)

            {:error, reason} ->
              Logger.error("RAG tool: embedding generation failed", error: inspect(reason))
              {:error, "Embedding generation failed: #{inspect(reason)}"}
          end
        end
    end
  end

  def run(params, context) when is_list(context) do
    run(params, %{resource_ids: context})
  end

  def run(_params, _context) do
    {:ok, %{results: [], message: "No documents available. The user hasn't uploaded any files."}}
  end

  @doc false
  def resolve_file_ids(context, actor) do
    user_id =
      if Map.get(context, :can_access_global_files, true),
        do: Map.get(context, :user_id),
        else: nil

    direct_file_ids =
      get_file_ids_for_conversation(
        Map.get(context, :conversation_id),
        Map.get(context, :folder_id),
        user_id,
        Map.get(context, :workspace_id),
        actor
      )

    knowledge_file_ids =
      if Map.get(context, :can_access_knowledge, true) do
        case Magus.Knowledge.get_accessible_file_ids(
               user_id: Map.get(context, :user_id),
               workspace_id: Map.get(context, :workspace_id),
               custom_agent_id: Map.get(context, :custom_agent_id)
             ) do
          {:ok, ids} -> ids
          _ -> []
        end
      else
        []
      end

    # Legacy: support explicit resource_ids from context
    legacy_ids =
      case Map.get(context, :resource_ids) do
        ids when is_list(ids) -> ids
        _ -> []
      end

    Enum.uniq(direct_file_ids ++ knowledge_file_ids ++ legacy_ids)
  end

  defp search_and_format(embedding, file_ids, limit, query, actor) do
    case Magus.Files.search_chunks(embedding, file_ids, limit, actor: actor) do
      {:ok, chunks} ->
        results = format_results(chunks, actor)

        {:ok,
         %{
           results: results,
           query: query,
           num_results: length(results),
           hint:
             "Always cite the source of each piece of information by linking to the download_url of the result."
         }}

      {:error, reason} ->
        Logger.error("RAG tool: search failed", error: inspect(reason))
        {:error, "Search failed: #{inspect(reason)}"}
    end
  end

  defp format_results(chunks, actor) do
    chunks
    |> Ash.load!([file: [:name, knowledge_collection: [:name]]], actor: actor)
    |> Enum.reject(&is_nil(&1.file))
    |> Enum.map(fn chunk ->
      file = chunk.file

      result = %{
        content: chunk.content,
        source: file.name,
        chunk_position: chunk.position,
        download_url: "/files/#{file.id}/download"
      }

      case file.knowledge_collection do
        %{name: collection_name} when is_binary(collection_name) ->
          Map.put(result, :knowledge_base, collection_name)

        _ ->
          result
      end
    end)
  end

  @doc """
  Gets all available file IDs for a conversation, including inherited folder and global files.

  Returns a list of file IDs that are ready for searching.
  """
  @spec get_file_ids_for_conversation(
          Ash.UUID.t() | nil,
          Ash.UUID.t() | nil,
          Ash.UUID.t() | nil,
          Ash.UUID.t() | nil,
          term()
        ) ::
          [Ash.UUID.t()]
  def get_file_ids_for_conversation(
        conversation_id,
        folder_id,
        user_id \\ nil,
        workspace_id \\ nil,
        actor \\ Magus.Agents.Tools.Helpers.ai_actor()
      ) do
    Logger.debug("Getting file IDs",
      conversation_id: conversation_id,
      folder_id: folder_id,
      user_id: user_id,
      workspace_id: workspace_id
    )

    conversation_files = get_conversation_files(conversation_id, actor)
    folder_files = get_folder_files(folder_id, actor)
    global_files = get_global_files(user_id, actor)
    workspace_files = get_workspace_files(workspace_id, actor)

    all_files = conversation_files ++ folder_files ++ global_files ++ workspace_files
    ready_files = Enum.filter(all_files, &(&1.status == :ready))
    file_ids = ready_files |> Enum.map(& &1.id) |> Enum.uniq()

    Logger.debug("File IDs collected",
      conversation_files: length(conversation_files),
      folder_files: length(folder_files),
      global_files: length(global_files),
      workspace_files: length(workspace_files),
      ready_files: length(ready_files)
    )

    file_ids
  end

  # Keep backwards compatibility alias
  def get_resource_ids_for_conversation(
        conversation_id,
        folder_id,
        user_id \\ nil,
        workspace_id \\ nil
      ) do
    get_file_ids_for_conversation(conversation_id, folder_id, user_id, workspace_id)
  end

  defp get_conversation_files(nil, _actor), do: []

  defp get_conversation_files(conversation_id, actor) do
    case Magus.Files.list_files_for_conversation(conversation_id, actor: actor) do
      {:ok, files} -> files
      {:error, _} -> []
    end
  end

  defp get_folder_files(nil, _actor), do: []

  defp get_folder_files(folder_id, actor) do
    case Magus.Files.list_files_for_folder(folder_id, actor: actor) do
      {:ok, files} -> files
      {:error, _} -> []
    end
  end

  defp get_global_files(nil, _actor), do: []

  defp get_global_files(user_id, actor) do
    case Magus.Files.list_global_files(user_id, actor: actor) do
      {:ok, files} -> files
      {:error, _} -> []
    end
  end

  defp get_workspace_files(nil, _actor), do: []

  defp get_workspace_files(workspace_id, actor) do
    case Magus.Files.list_files_for_workspace(workspace_id, actor: actor) do
      {:ok, files} -> files
      {:error, _} -> []
    end
  end
end
