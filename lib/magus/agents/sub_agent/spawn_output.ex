defmodule Magus.Agents.SubAgent.SpawnOutput do
  @moduledoc """
  Builds the terminal `tool_call_data.output` payload for a `spawn_sub_agent`
  event message once its child run has finished.

  This is what the parent's LLM sees as the tool result for the spawn call,
  via `Magus.Chat.Message.Calculations.AsLlmMessage.event_to_tool_result/1`.
  """

  alias Magus.Agents.AgentRun
  alias Magus.Agents.SubAgent.ResultEnrichment

  @type opts :: [skip_enrichment: boolean() | {:target_conversation_id, any()}]

  @spec build(AgentRun.t(), opts()) :: map()
  def build(%AgentRun{} = run, opts \\ []) do
    base = %{
      status: status_to_string(run.status),
      task_id: to_string(run.id),
      objective: run.objective,
      agent_name: agent_name(run),
      model: run.model_key,
      duration_ms: run.duration_ms,
      result_text: run.result_text,
      files_created: enriched_files(run, opts),
      tools_used: enriched_tools(run, opts)
    }

    if run.status == :error or run.status == :timed_out do
      Map.put(base, :error_message, run.error_message)
    else
      base
    end
  end

  defp status_to_string(:complete), do: "complete"
  defp status_to_string(:error), do: "error"
  defp status_to_string(:timed_out), do: "timed_out"
  defp status_to_string(:cancelled), do: "cancelled"
  defp status_to_string(other), do: to_string(other)

  defp agent_name(%AgentRun{metadata: meta}) when is_map(meta),
    do: meta["agent_name"] || meta[:agent_name]

  defp agent_name(_), do: nil

  defp enriched_files(_run, opts) do
    if Keyword.get(opts, :skip_enrichment, false), do: [], else: do_enriched_files(opts)
  end

  defp do_enriched_files(opts) do
    case Keyword.get(opts, :target_conversation_id) do
      nil -> []
      id -> ResultEnrichment.files_created(id)
    end
  end

  defp enriched_tools(_run, opts) do
    if Keyword.get(opts, :skip_enrichment, false) do
      []
    else
      case Keyword.get(opts, :target_conversation_id) do
        nil -> []
        id -> ResultEnrichment.tools_used(id).names
      end
    end
  end
end
