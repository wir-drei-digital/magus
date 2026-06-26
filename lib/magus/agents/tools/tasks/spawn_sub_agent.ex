defmodule Magus.Agents.Tools.Tasks.SpawnSubAgent do
  @moduledoc """
  Spawns an asynchronous sub-agent. Returns immediately with a `task_id`;
  the result is delivered to the parent's LLM context automatically when
  the sub-agent finishes (the spawn tool message's `output` field is mutated
  with the terminal payload).

  Two modes (in priority order):
  - **Custom agent** (highest): Pass `custom_agent_id` to inherit the agent's
    instructions, model, tools, and sampling settings automatically.
  - **Inline mode** (lowest): Pass `model_key` and/or `system_prompt` for
    quick one-off delegation without a pre-configured agent.

  Optional: call `await_sub_agents` if you must block this turn until N
  sub-agents finish. Otherwise rely on automatic delivery and continue
  your reasoning in subsequent turns.
  """

  use Jido.Action,
    name: "spawn_sub_agent",
    description: """
    Spawn a sub-agent to work on a specific objective.

    Two configuration modes (in priority order):
    1. **Custom agent** (custom_agent_id): Use a user-configured agent with its instructions, model, and tools.
    2. **Inline** (model_key + system_prompt): Quick one-off delegation.

    Returns task_id immediately. The sub-agent's result is delivered automatically
    to this tool call's output once the sub-agent finishes — its `output.status`
    will go from "spawning" to "complete" / "error", and `output.result_text`
    will hold the final response. You do not need to call await_sub_agents
    unless you want to block this turn until N sub-agents finish.

    You can spawn up to 3 sub-agents concurrently.

    For inspecting a sub-agent's full transcript, use fetch_sub_agent_transcript
    with the returned task_id.
    """,
    schema: [
      objective: [
        type: :string,
        required: true,
        doc: "Clear description of what the sub-agent should accomplish"
      ],
      custom_agent_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc:
          "ID of a custom agent to use. When set, inherits that agent's instructions, model, tools, and sampling settings."
      ],
      target_agent_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Alias for custom_agent_id."
      ],
      model_key: [
        type: {:or, [:string, nil]},
        default: nil,
        doc:
          "Model override for inline mode (e.g. 'openrouter:anthropic/claude-sonnet'). Ignored when custom_agent_id is set."
      ],
      system_prompt: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Custom instructions for inline mode. Ignored when custom_agent_id is set."
      ]
    ]

  require Logger

  import Magus.Agents.Tools.Helpers,
    only: [validate_context: 2, get_param: 2, extract_error_message: 1]

  alias Magus.Agents.{RunOrchestrator, Signals}

  @max_concurrent_sub_agents 3

  def display_name, do: "Spawning sub-agent..."

  def summarize_output(%{status: "spawning", objective: obj}),
    do: "Sub-agent spawning: #{String.slice(obj, 0, 80)}"

  def summarize_output(%{error: e}), do: "Error: #{e}"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id, :user_id, :user]) do
      {:ok, ctx} -> spawn_sub_agent(params, ctx, context)
      {:error, message} -> {:ok, %{error: message}}
    end
  end

  defp spawn_sub_agent(params, ctx, full_context) do
    objective = get_param(params, :objective)
    custom_agent_id = get_param(params, :target_agent_id) || get_param(params, :custom_agent_id)
    model_key_param = get_param(params, :model_key)
    system_prompt_param = get_param(params, :system_prompt)

    with :ok <- check_concurrency_limit(ctx.conversation_id),
         {:ok, config} <-
           resolve_config(
             custom_agent_id,
             model_key_param,
             system_prompt_param,
             full_context
           ),
         {:ok, child} <- create_child_conversation(config, objective, ctx, full_context),
         {:ok, run} <- create_run_record(child, config, objective, ctx, full_context) do
      Signals.emit_tool_progress(full_context, :spawning, %{
        objective: String.slice(objective, 0, 200),
        model: config.model_key,
        agent_name: config.agent_name
      })

      child_conversation_id = to_string(child.id)

      agent_type =
        if custom_agent_id do
          :custom
        else
          :inline
        end

      Signals.emit_tool_progress(full_context, :task_spawned, %{
        task_id: to_string(run.id),
        objective: objective,
        agent_type: agent_type,
        child_conversation_id: child_conversation_id,
        target_conversation_id: child_conversation_id,
        model: config.model_key,
        agent_name: config.agent_name
      })

      {:ok,
       %{
         status: "spawning",
         task_id: to_string(run.id),
         objective: objective,
         model: config.model_key,
         agent_name: config.agent_name,
         child_conversation_id: child_conversation_id,
         target_conversation_id: child_conversation_id
       }}
    else
      {:error, :concurrency_limit} ->
        {:ok,
         %{
           error:
             "Maximum of #{@max_concurrent_sub_agents} concurrent sub-agents reached. Wait for one to complete."
         }}

      {:error, error} ->
        {:ok, %{error: extract_error_message(error)}}
    end
  end

  defp check_concurrency_limit(conversation_id) do
    case Magus.Agents.running_agent_runs(conversation_id, authorize?: false) do
      {:ok, runs} when length(runs) >= @max_concurrent_sub_agents ->
        {:error, :concurrency_limit}

      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "SpawnSubAgent: concurrency check failed, allowing spawn: #{inspect(reason)}"
        )

        :ok
    end
  end

  # Priority 1: Custom agent mode (custom_agent_id takes highest priority)
  defp resolve_config(
         custom_agent_id,
         _model_key_param,
         _system_prompt_param,
         context
       )
       when is_binary(custom_agent_id) and custom_agent_id != "" do
    case Magus.Agents.get_custom_agent(custom_agent_id,
           load: [:model],
           authorize?: false
         ) do
      {:ok, agent} ->
        model_key =
          if agent.model do
            agent.model.key
          else
            Map.get(context, :__parent_model_key__) || default_model_key()
          end

        {:ok,
         %{
           custom_agent_id: custom_agent_id,
           model_key: model_key,
           system_prompt: nil,
           agent_name: agent.name
         }}

      {:error, _} ->
        {:error, "Custom agent not found: #{custom_agent_id}"}
    end
  end

  # Priority 2: Inline mode (model_key + system_prompt fallback)
  defp resolve_config(
         _custom_agent_id,
         model_key_param,
         system_prompt_param,
         context
       ) do
    model_key = model_key_param || Map.get(context, :__parent_model_key__) || default_model_key()

    prompt =
      if system_prompt_param do
        """
        #{system_prompt_param}

        Complete the given objective thoroughly, then stop. Do not ask follow-up questions.
        """
      else
        "You are a helpful sub-agent. Complete the given objective thoroughly, then stop. Do not ask follow-up questions."
      end

    {:ok,
     %{
       custom_agent_id: nil,
       model_key: model_key,
       system_prompt: prompt,
       agent_name: model_key
     }}
  end

  defp create_child_conversation(config, _objective, ctx, full_context) do
    sandbox_conversation_id = resolve_sandbox_conversation_id(ctx.conversation_id)

    attrs = %{
      is_task_conversation: true,
      parent_conversation_id: ctx.conversation_id,
      sandbox_conversation_id: sandbox_conversation_id
    }

    attrs =
      if config.custom_agent_id do
        Map.put(attrs, :custom_agent_id, config.custom_agent_id)
      else
        Map.put(attrs, :system_prompt, config.system_prompt)
      end

    # workspace_id is an optional enrichment from the tool context (set by
    # Preflight and ToolBuilder for workspace conversations). Read from the
    # raw full_context because validate_context only captures required keys.
    attrs =
      case Map.get(full_context, :workspace_id) do
        nil -> attrs
        workspace_id -> Map.put(attrs, :workspace_id, workspace_id)
      end

    Magus.Chat.create_conversation(attrs, actor: ctx.user)
  end

  defp resolve_sandbox_conversation_id(parent_conversation_id) do
    case Magus.Chat.get_conversation(parent_conversation_id, authorize?: false) do
      {:ok, parent} ->
        parent.sandbox_conversation_id || parent.id

      _ ->
        parent_conversation_id
    end
  end

  defp create_run_record(child, config, objective, ctx, full_context) do
    source_event_id = extract_source_event_id(full_context)

    RunOrchestrator.enqueue(%{
      kind: :subtask,
      source_conversation_id: ctx.conversation_id,
      source_event_id: source_event_id,
      target_conversation_id: child.id,
      target_agent_id: config.custom_agent_id,
      initiator_user_id: ctx.user_id,
      request_id: "subtask:#{Ash.UUIDv7.generate()}",
      idempotency_key: nil,
      model_key: config.model_key,
      objective: objective,
      metadata: %{agent_name: config.agent_name}
    })
  end

  defp extract_source_event_id(context) do
    case Map.get(context, :__event_id__) do
      nil -> nil
      event_id -> Magus.Agents.Plugins.Support.Helpers.tool_event_id_for_call_id(event_id)
    end
  end

  defp default_model_key do
    Magus.Models.Roles.resolve(:sub_agent_default)
  end
end
