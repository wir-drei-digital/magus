defmodule Magus.Agents.Tools.Autonomy.ListInboxEvents do
  @moduledoc """
  Returns the agent's inbox events still requiring attention. Used during
  autonomous wake-up to decide what to act on.
  """
  use Jido.Action,
    name: "list_inbox_events",
    description: "Returns inbox events still requiring attention (pending or waiting).",
    schema: [
      limit: [type: :integer, default: 50, doc: "Max events to return (1..200)"]
    ]

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2, ai_actor: 0]

  def display_name, do: "Listing inbox events..."

  def summarize_output(%{events: events}) when is_list(events),
    do: "Found #{length(events)} inbox event(s)"

  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:user_id, :custom_agent_id]) do
      {:ok, ctx} ->
        limit = params |> Map.get(:limit, 50) |> max(1) |> min(200)

        events =
          ctx.custom_agent_id
          |> Magus.Agents.list_pending_events!(actor: ai_actor())
          |> Enum.take(limit)
          |> Enum.map(&format_event/1)

        {:ok, %{events: events, count: length(events)}}

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp format_event(event) do
    now = DateTime.utc_now()

    %{
      id: event.id,
      title: event.title,
      event_type: event.event_type,
      urgency: event.urgency,
      source_type: event.source_type,
      summary: event.summary,
      age_seconds: DateTime.diff(now, event.inserted_at, :second)
    }
  end
end
