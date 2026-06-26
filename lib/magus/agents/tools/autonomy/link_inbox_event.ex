defmodule Magus.Agents.Tools.Autonomy.LinkInboxEvent do
  @moduledoc """
  Links an inbox event to the agent's currently active autonomous run so it
  gets resolved when the run completes successfully (or unlinked if the run
  fails). Use this when the agent intends to act on the event using its
  other tools, instead of dismissing it.

  Producer side of the AgentInboxEvent ↔ AgentRun linkage. Without a call
  to this tool, `AgentRunCompletionPlugin.resolve_linked_inbox_events/1`
  has nothing to resolve, even though the resolution path is live.
  """
  use Jido.Action,
    name: "link_inbox_event",
    description:
      "Link an inbox event to your current autonomous run so it's resolved on completion. Use this when you're going to act on the event with other tools (instead of dismissing it).",
    schema: [
      event_id: [type: :string, required: true, doc: "Event UUID"]
    ]

  require Ash.Query

  import Magus.Agents.Tools.Helpers,
    only: [validate_context: 2, ai_actor: 0, get_param: 2, extract_error_message: 1]

  def display_name, do: "Linking event to run..."
  def summarize_output(%{status: "linked"}), do: "Event linked"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:user_id, :custom_agent_id]) do
      {:ok, ctx} ->
        actor = ai_actor()
        event_id = get_param(params, :event_id)

        with {:ok, event} <- fetch_event(event_id, ctx.custom_agent_id, actor),
             {:ok, run_id} <- find_run_id(context, ctx.custom_agent_id) do
          do_link(event, run_id, actor)
        else
          {:error, message} -> {:ok, %{error: message}}
        end

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp fetch_event(event_id, custom_agent_id, actor) do
    case Ash.get(Magus.Agents.AgentInboxEvent, event_id, actor: actor) do
      {:ok, %{agent_id: ^custom_agent_id} = event} ->
        {:ok, event}

      {:ok, _other} ->
        {:error, "Event does not belong to this agent"}

      {:error, _} ->
        {:error, "Event not found"}
    end
  end

  # Prefer the explicit agent_run_id from tool context if the runner threaded
  # it through; otherwise fall back to looking up the most recent
  # heartbeat/manual_trigger run for this agent that is still pending or
  # running.
  defp find_run_id(context, custom_agent_id) do
    case context[:agent_run_id] || context["agent_run_id"] do
      run_id when is_binary(run_id) and run_id != "" ->
        {:ok, run_id}

      _ ->
        lookup_active_autonomous_run(custom_agent_id)
    end
  end

  defp lookup_active_autonomous_run(custom_agent_id) do
    Magus.Agents.AgentRun
    |> Ash.Query.filter(
      target_agent_id == ^custom_agent_id and
        source in [:heartbeat, :manual_trigger] and
        status in [:pending, :running]
    )
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> List.first()
    |> case do
      nil -> {:error, "No active autonomous run for this agent"}
      run -> {:ok, run.id}
    end
  end

  defp do_link(event, run_id, actor) do
    case Magus.Agents.link_event_to_run(event, run_id, actor: actor) do
      {:ok, _} ->
        {:ok, %{status: "linked", event_id: event.id, run_id: run_id}}

      {:error, error} ->
        {:ok, %{error: extract_error_message(error)}}
    end
  end
end
