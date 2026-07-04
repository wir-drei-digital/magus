defmodule Magus.Skills.Loader do
  @moduledoc """
  Shared skill-loading logic used by both the `load_skill` tool and the message
  preflight (slash-command triggers). Resolves a ref, persists the skill body +
  tool names onto the conversation, and for bundled skills enforces the approval
  gate and materializes into the sandbox.

  `load/3` returns `{:ok, result_map}`; errors are carried inside the map (a
  loaded skill's instructions are user-facing content, never a raised error).
  """

  require Logger

  alias Magus.Agents.Skills.Registry
  alias Magus.Agents.Tools.ToolBuilder

  @type context :: %{
          optional(:user) => struct() | nil,
          conversation_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t()
        }

  @spec load(String.t(), context(), keyword()) :: {:ok, map()}
  def load(ref, context, opts \\ []) do
    source = Keyword.get(opts, :source, :approval_card)

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
            handle_bundled_skill(context, skill, base, tools, source)
        end

      :not_found ->
        available = Registry.list_skills() |> Enum.map(&("builtin:" <> &1.name)) |> Enum.sort()
        {:ok, %{error: "Skill '#{ref}' not found", available_skills: available}}
    end
  end

  defp resolve("user:" <> id, context) do
    actor = Map.get(context, :user)

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

  # source is threaded for slash-invocation approval recording (Task 3 wires the
  # :slash_command path). Here it only distinguishes whether to auto-record.
  defp handle_bundled_skill(context, skill, base, tools, source) do
    conversation_id = Map.get(context, :conversation_id)
    user_id = Map.get(context, :user_id)

    case Magus.Chat.get_conversation(conversation_id, authorize?: false) do
      {:ok, conversation} ->
        maybe_autorecord(source, conversation, skill, user_id)

        # Reload to observe an approval just recorded by a slash invocation.
        conversation =
          case Magus.Chat.get_conversation(conversation_id, authorize?: false) do
            {:ok, c} -> c
            _ -> conversation
          end

        approved? =
          Magus.Skills.Approval.approved?(conversation, skill) or
            trusted_and_record(conversation, skill, user_id)

        if approved? do
          materialize(context, skill, base, tools, conversation_id, user_id)
        else
          Magus.Skills.Approval.request(conversation_id, skill, user_id)

          {:ok,
           Map.merge(base, %{
             status: "pending",
             hint:
               "This skill bundles code that runs in the sandbox. STOP and ask the user to approve it by replying exactly: " <>
                 Magus.Skills.Approval.approve_phrase(skill.id) <>
                 ". After they approve, call load_skill again with the same ref to install and use it."
           })}
        end

      _ ->
        {:ok, Map.put(base, :error, "Could not load conversation to check skill approval.")}
    end
  end

  # A user-typed slash invocation IS the human-in-the-loop consent, so record the
  # approval before the gate check (Plan 2A spec, "slash = approval").
  defp maybe_autorecord(:slash_command, conversation, skill, user_id) do
    Magus.Skills.record_conversation_approval(
      %{
        conversation_id: conversation.id,
        skill_id: skill.id,
        bundle_sha: Map.get(skill, :bundle_sha),
        approved_by_id: user_id,
        source: :slash_command
      },
      authorize?: false
    )
  end

  defp maybe_autorecord(_source, _conversation, _skill, _user_id), do: :ok

  # An agent-initiated load of a skill the user has explicitly trusted is honored
  # without a fresh approval card: record a :trusted approval so materialization
  # proceeds. Returns true only when the user trusts the skill (and the trusted
  # sha still matches, per Approval.trusted?/2).
  defp trusted_and_record(conversation, skill, user_id) do
    if user_id && Magus.Skills.Approval.trusted?(user_id, skill) do
      Magus.Skills.record_conversation_approval(
        %{
          conversation_id: conversation.id,
          skill_id: skill.id,
          bundle_sha: Map.get(skill, :bundle_sha),
          approved_by_id: user_id,
          source: :trusted
        },
        authorize?: false
      )

      true
    else
      false
    end
  end

  defp materialize(_context, skill, base, tools, conversation_id, user_id) do
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
  end

  defp persist_context_and_tools(context, content, tools, already_loaded?) do
    conversation_id = Map.get(context, :conversation_id)

    if conversation_id != nil and content not in [nil, ""] do
      case Magus.Chat.get_conversation(conversation_id, authorize?: false) do
        {:ok, conversation} ->
          existing_context = conversation.skill_context || ""
          existing_tools = conversation.skill_tools || []

          unless already_loaded?.(existing_context, existing_tools) do
            merged_context =
              if existing_context == "",
                do: content,
                else: existing_context <> "\n\n---\n\n" <> content

            merged_tools = Enum.uniq(existing_tools ++ tools)

            case Magus.Chat.set_conversation_skill(
                   conversation,
                   %{skill_context: merged_context, skill_tools: merged_tools},
                   authorize?: false
                 ) do
              {:ok, _} -> :ok
              {:error, reason} -> Logger.warning("persist skill failed: #{inspect(reason)}")
            end
          end

        _ ->
          :ok
      end
    end
  end

  defp persist_user_skill(context, body, tools) do
    body = body || ""

    persist_context_and_tools(context, body, tools, fn existing_context, _existing_tools ->
      String.contains?(existing_context, body)
    end)
  end

  defp persist_skill(context, skill) do
    new_tools = skill.tools || []

    persist_context_and_tools(context, skill.content, new_tools, fn _existing, existing_tools ->
      new_tools != [] and Enum.all?(new_tools, &(&1 in existing_tools))
    end)
  end

  defp maybe_attach_new_tools(result, tool_names) do
    case ToolBuilder.resolve_skill_tools(tool_names) do
      [] -> result
      modules -> Map.put(result, :__new_tools__, modules)
    end
  end
end
