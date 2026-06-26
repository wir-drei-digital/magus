defmodule Magus.Agents.Tools.Search.LoadTool do
  @moduledoc """
  Enable one or more tools found via tool_search. Loaded tools become callable on
  the next step and stay available for the rest of the conversation.

  Persists tool names on the conversation (via Conversation.loaded_tools) so they
  survive across turns and agent hibernation, and attaches `__new_tools__` so the
  ReAct runner registers them mid-turn.

  MCP-aware: resolution is actor-scoped (`Catalog.resolve/2`). Accessible MCP
  tools are persisted by their coined name alongside resolved module names and
  returned under `__new_mcp_tools__` (carrier entries). Names the actor cannot
  access are reported under `unknown` and never persisted.
  """

  use Jido.Action,
    name: "load_tool",
    description: """
    Enable tools you found with tool_search so you can call them. Pass the exact
    tool names. You can load several at once. Loaded tools stay available for the
    rest of this conversation. After loading, call the tool on your next step.
    """,
    schema: [
      names: [
        type: {:list, :string},
        required: true,
        doc: "Exact tool names to load, as returned by tool_search"
      ]
    ]

  alias Magus.Agents.Tools.Catalog
  alias Magus.Agents.Tools.Search.ActorContext

  import Magus.Agents.Tools.Helpers, only: [get_param: 2, get_context_value: 2]

  @doc "User-friendly display name shown in the UI when this tool is executing"
  def display_name, do: "Loading tools..."

  @doc "Generate a human-readable summary of the tool output for UI display"
  def summarize_output(%{loaded: loaded}) when is_list(loaded) and loaded != [],
    do: "Loaded: #{Enum.join(loaded, ", ")}"

  def summarize_output(_), do: "No tools loaded"

  @impl true
  def run(params, context) do
    names = get_param(params, :names) || []
    actor_context = ActorContext.from(context)

    {modules, mcp_tools, unknown} = Catalog.resolve(names, actor_context)

    module_names = Enum.map(modules, & &1.name())
    # Persist ONLY accessible coined names -- the ones resolve/2 actually
    # returned. Inaccessible names are in `unknown` and never persisted.
    mcp_names = Enum.map(mcp_tools, & &1.coined_name)
    loaded = module_names ++ mcp_names

    persist_loaded_tools(context, loaded)

    result = %{loaded: loaded, unknown: unknown}
    result = if modules == [], do: result, else: Map.put(result, :__new_tools__, modules)
    result = if mcp_tools == [], do: result, else: Map.put(result, :__new_mcp_tools__, mcp_tools)

    {:ok, result}
  end

  # Merge newly loaded names into Conversation.loaded_tools so they persist for
  # the rest of the session. Mirrors the persistence pattern in LoadSkill.
  defp persist_loaded_tools(_context, []), do: :ok

  defp persist_loaded_tools(context, names) do
    conversation_id = get_context_value(context, :conversation_id)

    if conversation_id do
      case Magus.Chat.get_conversation(conversation_id, authorize?: false) do
        {:ok, conversation} ->
          existing = conversation.loaded_tools || []
          merged = Enum.uniq(existing ++ names)

          if merged != existing do
            Magus.Chat.set_conversation_loaded_tools(
              conversation,
              %{loaded_tools: merged},
              authorize?: false
            )
          end

        _ ->
          :ok
      end
    end

    :ok
  end
end
