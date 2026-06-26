defmodule Magus.Agents.Tools.Files.SearchAttachedDocs do
  @moduledoc """
  Searches the documents attached (in :search mode) to the current
  custom agent. Reuses the standard pgvector-backed chunk search,
  filtered to file ids that belong to this agent's :search attachments.
  """

  use Jido.Action,
    name: "search_attached_docs",
    description:
      "Search the documents attached to this agent (in 'search' mode) for content relevant to the query. Use this when you need details from a reference document the user has attached to you.",
    schema: [
      query: [type: :string, required: true, doc: "Natural-language query."],
      limit: [
        type: :integer,
        required: false,
        default: 5,
        doc: "Maximum number of result chunks (max 25)."
      ]
    ]

  require Ash.Query
  require Logger

  alias Magus.Agents.Signals
  alias Magus.Agents.Tools.Helpers
  alias Magus.Files.EmbeddingModel

  def display_name, do: "Searching attached documents..."

  def summarize_output(%{results: results}) when is_list(results),
    do: "Found #{length(results)} matching passages."

  def summarize_output(%{error: e}), do: "Error: #{e}"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case Helpers.validate_context(context, [:custom_agent_id]) do
      {:ok, ctx} ->
        do_run(params, Map.merge(context, ctx))

      {:error, msg} ->
        {:ok, %{error: msg}}
    end
  end

  defp do_run(params, %{custom_agent_id: agent_id} = ctx) do
    query = Helpers.get_param(params, :query)
    limit = (Helpers.get_param(params, :limit) || 5) |> min(25) |> max(1)

    Signals.emit_tool_progress(ctx, :searching, %{query: query})

    file_ids = search_mode_file_ids(agent_id)

    cond do
      not is_binary(query) or query == "" ->
        {:ok, %{results: []}}

      file_ids == [] ->
        {:ok, %{results: []}}

      true ->
        case EmbeddingModel.embed_query(query) do
          {:ok, embedding} ->
            do_search(embedding, file_ids, limit, ctx)

          {:error, reason} ->
            Logger.error("SearchAttachedDocs: embedding failed", error: inspect(reason))
            {:ok, %{error: "Embedding generation failed: #{inspect(reason)}"}}
        end
    end
  end

  @doc false
  def search_mode_file_ids(agent_id) do
    Magus.Agents.CustomAgentAttachment
    |> Ash.Query.filter(custom_agent_id == ^agent_id and mode == :search)
    |> Ash.Query.select([:file_id])
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.file_id)
  end

  @doc false
  def do_search(embedding, file_ids, limit, ctx) do
    actor = Map.get(ctx, :user) || Helpers.ai_actor()

    case Magus.Files.search_chunks(embedding, file_ids, limit, actor: actor) do
      {:ok, chunks} ->
        chunks = Ash.load!(chunks, [file: [:name]], actor: actor)

        results =
          Enum.map(chunks, fn c ->
            %{
              file_id: c.file_id,
              file_name: file_name_for(c),
              position: c.position,
              content: c.content
            }
          end)

        Enum.each(results, fn r ->
          Signals.emit_tool_progress(ctx, :result_found, %{
            file: r.file_name,
            position: r.position
          })
        end)

        {:ok, %{results: results}}

      {:error, reason} ->
        {:ok, %{error: "Search failed: #{inspect(reason)}"}}
    end
  end

  defp file_name_for(%{file: %{name: n}}) when is_binary(n), do: n
  defp file_name_for(_), do: "(unnamed)"
end
