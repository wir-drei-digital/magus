defmodule Magus.Agents.Tools.Autonomy.DismissEvent do
  @moduledoc """
  Dismisses (resolves without follow-up work) an inbox event. The
  agent calls this for noise or already-handled items during a
  wake-up run.
  """
  use Jido.Action,
    name: "dismiss_event",
    description:
      "Dismiss an inbox event (resolves without follow-up work). Provide a short reason for audit.",
    schema: [
      event_id: [type: :string, required: true, doc: "Event UUID"],
      reason: [type: :string, required: true, doc: "Why this event is being dismissed"]
    ]

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2, ai_actor: 0, get_param: 2]

  def display_name, do: "Dismissing event..."
  def summarize_output(%{status: "dismissed"}), do: "Event dismissed"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:user_id, :custom_agent_id]) do
      {:ok, ctx} ->
        actor = ai_actor()
        event_id = get_param(params, :event_id)
        reason = get_param(params, :reason)

        case Ash.get(Magus.Agents.AgentInboxEvent, event_id, actor: actor) do
          {:ok, event} ->
            if event.agent_id == ctx.custom_agent_id do
              dismiss(event, reason, actor)
            else
              {:ok, %{error: "Event does not belong to this agent"}}
            end

          {:error, _} ->
            {:ok, %{error: "Event not found"}}
        end

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp dismiss(event, reason, actor) do
    case Magus.Agents.dismiss_event_by_agent(event, %{resolution_note: reason}, actor: actor) do
      {:ok, _} ->
        {:ok, %{status: "dismissed", event_id: event.id, reason: reason}}

      {:error, error} ->
        {:ok, %{error: format_error(error)}}
    end
  end

  defp format_error(%Ash.Error.Invalid{} = e), do: Exception.message(e)
  defp format_error(e), do: inspect(e)
end
