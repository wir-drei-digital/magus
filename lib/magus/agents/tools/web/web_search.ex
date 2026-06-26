defmodule Magus.Agents.Tools.Web.WebSearch do
  @moduledoc """
  Web search tool.

  Provides web search capabilities for agents, returning relevant results
  with titles, URLs, and content summaries. The concrete provider stays behind
  the `Magus.Capabilities.Search` seam (Exa by default).

  ## Configuration

  Requires a configured search provider (Exa: `EXA_API_KEY`). When none is
  configured the tool is gated off in `ToolBuilder` and otherwise returns a
  readable "not configured" message.

  ## Usage with Jido AI

      tools = [Magus.Agents.Tools.Web.WebSearch]

  ## Example Output

      Input: "latest developments in quantum computing 2024"
      Output: %{
        query: "latest developments in quantum computing 2024",
        results: [
          %{
            title: "Quantum Computing Breakthrough...",
            url: "https://example.com/article",
            summary: "Researchers have achieved...",
            published_date: "2024-12-15"
          }
        ]
      }
  """

  use Jido.Action,
    name: "web_search",
    description: """
    Search the web for current information.
    Use this when the user asks about recent events, news, or needs up-to-date information
    that may not be in your training data. Returns relevant web pages with summaries.
    """,
    schema: [
      query: [
        type: :string,
        required: true,
        doc: "The search query to find relevant web pages"
      ],
      num_results: [
        type: :integer,
        required: false,
        doc: "Number of results to return (1-10, default 5)"
      ],
      category: [
        type: :string,
        required: false,
        doc: "Filter by category: news, research paper, github, tweet, etc."
      ]
    ]

  require Logger

  alias Magus.Agents.Signals
  alias Magus.Capabilities.Search

  @default_num_results 5
  @max_results 10

  @doc "User-friendly display name shown in the UI when this tool is executing"
  def display_name, do: "Searching the web..."

  @doc "Generate a human-readable summary of the tool output for UI display"
  def summarize_output(%{results: results}) when is_list(results),
    do: "Found #{length(results)} results"

  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Search completed"

  @doc "System prompt context explaining when and how to use this tool"
  def system_prompt_context do
    """
    - web_search: Search the web for current information. You MUST use this tool to search for relevant information before answering the user's question.

    IMPORTANT: After using web_search, you MUST include a "Sources:" section at the end of your response listing all the URLs you used. Format each source as a markdown link on its own line:

    Sources:
    - [Title of Article](https://example.com/article)
    - [Another Source](https://example.com/other)

    This is mandatory - never skip including sources when you use web search results.
    """
  end

  @impl true
  def run(params, context) do
    query = String.trim(get_param(params, "query") || "")
    num_results = min(get_param(params, "num_results") || @default_num_results, @max_results)
    category = get_param(params, "category")

    if query == "" do
      {:ok, %{error: "Search query cannot be empty", query: "", results: []}}
    else
      # Emit progress: starting search
      Signals.emit_tool_progress(context, :searching, %{query: query})

      case Search.search(query, num_results: num_results, category: category) do
        {:ok, results} ->
          # Emit progress for each result found
          Enum.with_index(results, 1)
          |> Enum.each(fn {result, index} ->
            Signals.emit_tool_progress(context, :result_found, %{
              index: index,
              total: length(results),
              title: result.title,
              url: result.url
            })
          end)

          {:ok, %{query: query, results: results}}

        {:error, reason} ->
          error_message = format_search_error(reason)
          Logger.error("WebSearch failed", query: query, error: error_message)
          {:ok, %{error: "Search failed: #{error_message}", query: query, results: []}}
      end
    end
  end

  # Provider-agnostic error text for the agent/user (no provider name or env-var
  # leaks). The concrete adapter stays behind the Magus.Capabilities.Search seam.
  defp format_search_error(:not_configured), do: "web search is not configured"

  defp format_search_error({:http_error, status, _body}),
    do: "search provider returned HTTP #{status}"

  defp format_search_error({:transport_error, reason}), do: "network error: #{inspect(reason)}"
  defp format_search_error({:unknown_error, reason}), do: "unexpected error: #{inspect(reason)}"
  defp format_search_error(reason), do: "error: #{inspect(reason)}"

  # Get param by string key, falling back to atom key for compatibility
  defp get_param(params, key) when is_binary(key) do
    Map.get(params, key) || Map.get(params, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end
end
