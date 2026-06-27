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
    ref = get_param(params, :skill_name)

    case resolve(ref, context) do
      {:builtin, skill} ->
        persist_skill(context, skill)

        result = %{skill: skill.name, description: skill.description, content: skill.content}
        {:ok, maybe_attach_new_tools(result, skill.tools)}

      {:user, skill} ->
        tools = skill.requested_tools || []
        persist_user_skill(context, skill.body, tools)

        base = %{
          skill: skill.name,
          description: skill.description || "",
          content: skill.body || ""
        }

        cond do
          not skill.has_executable_bundle ->
            {:ok, maybe_attach_new_tools(base, tools)}

          not Magus.Sandbox.Provider.configured?() ->
            {:ok,
             Map.merge(base, %{
               unavailable: true,
               content:
                 base.content <>
                   "\n\n(This skill requires code execution, which is unavailable on this instance.)"
             })}

          true ->
            handle_bundled_skill(context, skill, base, tools)
        end

      :not_found ->
        available =
          Registry.list_skills() |> Enum.map(&("builtin:" <> &1.name)) |> Enum.sort()

        {:ok, %{error: "Skill '#{ref}' not found", available_skills: available}}
    end
  end

  # Resolve a load_skill ref to its source.
  # "user:<id>" -> DB skill (access-checked as the context user)
  # "builtin:<name>" or a bare name -> registry skill
  defp resolve("user:" <> id, context) do
    actor = get_context_value(context, :user)

    case actor && Magus.Skills.get_skill(id, actor: actor) do
      {:ok, skill} -> {:user, skill}
      _ -> :not_found
    end
  end

  defp resolve("builtin:" <> name, _context), do: registry_lookup(name)
  defp resolve(name, _context) when is_binary(name), do: registry_lookup(name)
  defp resolve(_, _), do: :not_found

  defp registry_lookup(name) do
    case Registry.get_skill(name) do
      {:ok, skill} -> {:builtin, skill}
      _ -> :not_found
    end
  end

  defp handle_bundled_skill(context, skill, base, tools) do
    conversation_id = get_context_value(context, :conversation_id)
    user_id = get_context_value(context, :user_id)

    case Magus.Chat.get_conversation(conversation_id, authorize?: false) do
      {:ok, conversation} ->
        if Magus.Skills.Approval.approved?(conversation, skill.id) do
          case Magus.Skills.Materializer.materialize(conversation_id, skill, user_id) do
            {:ok, dir} ->
              enriched =
                base
                |> Map.put(:materialized, dir)
                |> Map.put(
                  :content,
                  base.content <>
                    "\n\nThis skill is installed at #{dir}. If it needs secrets, `source /workspace/.env` first."
                )

              {:ok, maybe_attach_new_tools(enriched, tools)}

            {:error, reason} ->
              {:ok, Map.put(base, :error, "Could not install skill: #{inspect(reason)}")}
          end
        else
          Magus.Skills.Approval.request(conversation_id, skill, user_id)

          {:ok,
           Map.merge(base, %{
             status: "pending",
             hint:
               "This skill bundles code that runs in the sandbox. STOP and wait for the user to approve. After they approve, call load_skill again with the same ref to install and use it."
           })}
        end

      _ ->
        {:ok, Map.put(base, :error, "Could not load conversation to check skill approval.")}
    end
  end

  # Persist a user skill's body + requested tool names onto the conversation,
  # mirroring persist_skill/2 but sourced from a Magus.Skills.Skill.
  defp persist_user_skill(context, body, tools) do
    conversation_id = get_context_value(context, :conversation_id)
    body = body || ""

    if conversation_id != nil and body != "" do
      case Magus.Chat.get_conversation(conversation_id, authorize?: false) do
        {:ok, conversation} ->
          existing_context = conversation.skill_context || ""
          existing_tools = conversation.skill_tools || []

          # Skip if this exact body is already present (idempotent re-load).
          unless String.contains?(existing_context, body) do
            merged_context =
              if existing_context == "", do: body, else: existing_context <> "\n\n---\n\n" <> body

            merged_tools = Enum.uniq(existing_tools ++ tools)

            case Magus.Chat.set_conversation_skill(
                   conversation,
                   %{skill_context: merged_context, skill_tools: merged_tools},
                   authorize?: false
                 ) do
              {:ok, _} -> :ok
              {:error, reason} -> Logger.warning("persist_user_skill failed: #{inspect(reason)}")
            end
          end

        _ ->
          :ok
      end
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
