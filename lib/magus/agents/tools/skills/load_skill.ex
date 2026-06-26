defmodule Magus.Agents.Tools.Skills.LoadSkill do
  @moduledoc """
  Tool for loading skill instructions into the conversation context.

  When skills are loaded, their content is returned as the tool result,
  allowing the AI to use the specialized instructions for the current task.
  Multiple skills can be loaded by calling this tool multiple times.

  ## Usage with Jido AI

      # As a tool in ChatResponder
      tools = [Magus.Agents.Tools.Skills.LoadSkill]
      tool_contexts = %{
        Magus.Agents.Tools.Skills.LoadSkill => %{}
      }

  ## Example

      Input: %{skill_name: "poetry_writing"}
      Output: %{skill: "poetry_writing", content: "# Poetry Writing\n\nWhen helping..."}
  """

  use Jido.Action,
    name: "load_skill",
    description: """
    Load specialized instructions and tools for a specific task type.
    Loading a skill unlocks its specialized tools and provides detailed guidance.
    You can load multiple skills — each adds to the available toolset.

    Available skills are listed in your system prompt under "Available Skills".
    """,
    schema: [
      skill_name: [
        type: :string,
        required: true,
        doc: "Name of the skill to load (from the available skills list)"
      ]
    ]

  require Logger

  alias Magus.Agents.Skills.Registry
  alias Magus.Agents.Tools.ToolBuilder

  @doc "User-friendly display name shown in the UI when this tool is executing"
  def display_name, do: "Loading skill..."

  @doc "Generate a human-readable summary of the tool output for UI display"
  def summarize_output(%{skill: name}), do: "Loaded: #{name}"
  def summarize_output(%{error: _}), do: "Skill not found"
  def summarize_output(_), do: "Completed"

  import Magus.Agents.Tools.Helpers, only: [get_param: 2, get_context_value: 2]

  @impl true
  def run(params, context) do
    skill_name = get_param(params, :skill_name)

    case Registry.get_skill(skill_name) do
      {:ok, skill} ->
        persist_skill(context, skill)

        result = %{
          skill: skill.name,
          description: skill.description,
          content: skill.content
        }

        {:ok, maybe_attach_new_tools(result, skill.tools)}

      {:error, :not_found} ->
        available_skills =
          Registry.list_skills()
          |> Enum.map(& &1.name)
          |> Enum.sort()

        {:ok,
         %{
           error: "Skill '#{skill_name}' not found",
           available_skills: available_skills
         }}
    end
  end

  # Attach resolved tool modules so the ReAct runner can register them mid-turn.
  defp maybe_attach_new_tools(result, tool_names) do
    case ToolBuilder.resolve_skill_tools(tool_names) do
      [] -> result
      modules -> Map.put(result, :__new_tools__, modules)
    end
  end

  # Persist skill context and tools on the conversation so they remain
  # available for all subsequent messages in the session.
  # Note: tool event messages are filtered out of LLM context on subsequent
  # turns (message_type == :message only), so skill_context is the only way
  # the skill instructions survive across turns.
  defp persist_skill(context, skill) do
    conversation_id = get_context_value(context, :conversation_id)

    if conversation_id do
      case Magus.Chat.get_conversation(conversation_id, authorize?: false) do
        {:ok, conversation} ->
          existing_context = conversation.skill_context || ""
          existing_tools = conversation.skill_tools || []
          new_tools = skill.tools || []

          # Skip if this skill's tools are already loaded (prevents duplicate context)
          already_loaded? =
            new_tools != [] and Enum.all?(new_tools, &(&1 in existing_tools))

          unless already_loaded? do
            merged_context =
              if existing_context == "",
                do: skill.content,
                else: existing_context <> "\n\n---\n\n" <> skill.content

            merged_tools = Enum.uniq(existing_tools ++ new_tools)

            Magus.Chat.set_conversation_skill(
              conversation,
              %{
                skill_context: merged_context,
                skill_tools: merged_tools
              },
              authorize?: false
            )
          end

        _ ->
          :ok
      end
    end
  end
end
