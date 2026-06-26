defmodule Magus.Agents.SlashCommands do
  @moduledoc """
  Global slash command registry and parser.

  Slash commands are `/name` prefixes at the start of a user message. When parsed,
  the command is replaced with an `<instruction>` block that guides the LLM, while
  the remaining text is passed through as the user's freeform input.

  Commands come from two sources:
  - Global commands defined in this module (available in every conversation)
  - Agent commands defined on CustomAgent (available when that agent is active)

  Agent commands override globals when they share the same name.
  """

  @global_commands [
    %{
      name: "web-search",
      title: %{en: "Search the web", de: "Im Web suchen"},
      instruction:
        "Use the web_search tool to answer the user's question. Search for recent information when the query involves current events or facts that may have changed. Cite your sources when providing information from search results. If search results are unclear or conflicting, acknowledge the uncertainty.",
      icon: "lucide-globe"
    },
    %{
      name: "reminder",
      title: %{en: "Set a reminder", de: "Erinnerung erstellen"},
      instruction: "Load the workflow skill and create a job as per the user's request.",
      icon: "lucide-bell"
    },
    %{
      name: "draft",
      title: %{en: "Create a draft", de: "Entwurf erstellen"},
      instruction: "Create a new draft document based on the user's request.",
      icon: "lucide-file-text"
    },
    %{
      name: "brainstorming",
      title: %{en: "Refine ideas", de: "Ideen verfeinern"},
      instruction: "Load the brainstorming skill to turn vague ideas into a structured plan.",
      icon: "lucide-brain"
    },
    %{
      name: "council",
      title: %{en: "Get multiple perspectives", de: "Mehrere Perspektiven einholen"},
      instruction:
        "Load the council skill to get multiple expert perspectives on the user's question or plan.",
      icon: "lucide-users"
    }
  ]

  @doc "Returns the list of global slash commands."
  def list, do: @global_commands

  @doc """
  Resolve a command's title for the current locale.
  Accepts a title map like `%{en: "...", de: "..."}` or a plain string.
  """
  def title(%{} = title_map) do
    locale = Gettext.get_locale(MagusWeb.Gettext)

    # Agent-defined commands round-trip through JSONB, so their title maps
    # carry string keys; globals use atom keys. Try both.
    Map.get(title_map, safe_atom(locale)) || Map.get(title_map, locale) ||
      Map.get(title_map, :en) || Map.get(title_map, "en", "")
  end

  def title(title) when is_binary(title), do: title
  def title(_), do: ""

  defp safe_atom(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> :en
  end

  @doc """
  Look up a command by name. Checks agent commands first, then globals.
  Returns the command map or nil.
  """
  def get(name, agent_commands \\ [])

  def get(name, agent_commands) when is_list(agent_commands) do
    Enum.find(agent_commands, &(to_string(&1.name) == name)) ||
      Enum.find(@global_commands, &(&1.name == name))
  end

  @doc """
  Merge global and agent commands. Agent commands override globals by name.
  Returns plain maps with atom keys for consistent access regardless of source.
  """
  def merge(agent_commands) when is_list(agent_commands) and agent_commands != [] do
    normalized = Enum.map(agent_commands, &to_map/1)
    agent_names = MapSet.new(normalized, & &1.name)

    globals_without_overrides =
      Enum.reject(@global_commands, &MapSet.member?(agent_names, &1.name))

    normalized ++ globals_without_overrides
  end

  def merge(_), do: @global_commands

  defp to_map(%{__struct__: _} = struct) do
    Map.take(struct, [:name, :title, :instruction, :icon])
  end

  defp to_map(map) when is_map(map), do: map

  @doc """
  Parse a message for a leading slash command.

  Returns `{instruction, remaining_text}` where instruction is either
  an `<instruction>...</instruction>` string or nil if no command matched.
  """
  def parse(text, agent_commands \\ [])

  def parse(nil, _agent_commands), do: {nil, ""}
  def parse("", _agent_commands), do: {nil, ""}

  def parse("/" <> rest, agent_commands) do
    {command_name, remaining} =
      case String.split(rest, ~r/\s/, parts: 2) do
        [name] -> {name, ""}
        [name, text] -> {name, String.trim(text)}
      end

    case get(command_name, agent_commands) do
      nil ->
        {nil, "/" <> rest}

      command ->
        instruction = "<instruction>#{command.instruction}</instruction>"
        {instruction, remaining}
    end
  end

  def parse(text, _agent_commands), do: {nil, text}
end
