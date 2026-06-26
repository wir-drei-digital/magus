defmodule Magus.Integrations.Providers.GoogleCalendar.Tools.DeleteEvent do
  @moduledoc """
  Tool for deleting an event from Google Calendar.

  This tool requires the Google Calendar integration to be enabled
  and the `delete_event` tool to be enabled for the user.
  """

  use Jido.Action,
    name: "delete_calendar_event",
    description: "Delete an event from your Google Calendar",
    schema: [
      event_id: [
        type: :string,
        required: true,
        doc: "The ID of the event to delete"
      ],
      calendar_id: [
        type: :string,
        default: "primary",
        doc: "Calendar ID containing the event. Use 'primary' for the main calendar."
      ]
    ]

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2, get_param: 2, get_param: 3]

  alias Magus.Agents.Signals
  alias Magus.Integrations.Providers.GoogleCalendar.Tools.Helpers, as: CalHelpers
  alias Magus.Integrations.Reactors.RunIntegration

  def display_name, do: "Deleting calendar event..."

  def summarize_output(%{deleted: true}), do: "Event deleted"
  def summarize_output(%{error: error}), do: "Error: #{error}"
  def summarize_output(_), do: "Deleted event"

  @impl true
  def run(params, context) do
    case validate_context(context, [:user_id]) do
      {:ok, ctx} ->
        event_id = get_param(params, :event_id)
        Signals.emit_tool_progress(context, :deleting, %{event_id: event_id})

        inputs = %{
          user_id: ctx.user_id,
          provider_key: :google_calendar,
          operation: :delete_event,
          params: %{
            event_id: event_id,
            calendar_id: get_param(params, :calendar_id, "primary")
          }
        }

        case Reactor.run(RunIntegration, inputs, async?: false) do
          {:ok, %{result: result}} ->
            Signals.emit_tool_progress(context, :deleted, %{})
            {:ok, result}

          {:error, reason} ->
            {:ok, %{error: CalHelpers.format_error(CalHelpers.extract_error(reason))}}
        end

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end
end
