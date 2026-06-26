defmodule Magus.Agents.Tools.Search.ToolSearch do
  @moduledoc """
  Search for tools you do not currently have loaded. Read-only: returns ranked
  matches by name, description, and category. Use `load_tool` to enable a match.
  """

  use Jido.Action,
    name: "tool_search",
    description: """
    Search for additional tools you do not currently have available, by keyword.
    Use this when a request needs a capability you cannot see in your current
    tools (for example calendars, images, spreadsheets, conversation history).
    This only finds tools. To actually use one, call load_tool with its name.
    """,
    schema: [
      query: [
        type: :string,
        required: true,
        doc: "Keywords describing the capability you need, e.g. 'add calendar event'"
      ],
      limit: [
        type: :integer,
        required: false,
        default: 5,
        doc: "Maximum number of matches to return"
      ]
    ]

  alias Magus.Agents.Tools.Catalog
  alias Magus.Agents.Tools.Search.ActorContext

  import Magus.Agents.Tools.Helpers, only: [get_param: 2, get_param: 3]

  @doc "User-friendly display name shown in the UI when this tool is executing"
  def display_name, do: "Searching for tools..."

  @doc "Generate a human-readable summary of the tool output for UI display"
  def summarize_output(%{matches: matches}) when is_list(matches),
    do: "Found #{length(matches)} tool(s)"

  def summarize_output(_), do: "Search completed"

  @impl true
  def run(params, context) do
    query = get_param(params, :query) || ""
    limit = get_param(params, :limit, 5)
    actor_context = ActorContext.from(context)

    # Fall back to listing all loadable tools when the query is blank or matches
    # nothing, so a vague or empty search still surfaces what can be loaded
    # instead of an empty result the model is tempted to ignore (and then
    # hallucinate around). The internal catalog is small; revisit the unbounded
    # fallback if/when MCP adds large numbers of tools.
    {entries, exact?} =
      case Catalog.search(query, limit: limit, context: actor_context) do
        [] -> {Catalog.entries(actor_context), false}
        found -> {found, true}
      end

    matches =
      Enum.map(entries, fn entry ->
        %{
          name: entry.name,
          description: entry.description,
          category: to_string(entry.category)
        }
      end)

    result = %{matches: matches}

    result =
      if exact?,
        do: result,
        else:
          Map.put(
            result,
            :note,
            "No exact match for the query. These are the tools you can load with load_tool."
          )

    {:ok, result}
  end
end
