defmodule Magus.Integrations.Providers.GoogleCalendar.Tools.ListEvents do
  @moduledoc """
  Tool for listing events from Google Calendar.

  This tool requires the Google Calendar integration to be enabled
  and the `list_events` tool to be enabled for the user.
  """

  use Jido.Action,
    name: "list_calendar_events",
    description: "List upcoming events from your Google Calendar",
    schema: [
      calendar_id: [
        type: :string,
        default: "primary",
        doc: "Calendar ID to list events from. Use 'primary' for the main calendar."
      ],
      max_results: [
        type: :integer,
        default: 10,
        doc: "Maximum number of events to return (1-50)"
      ],
      time_min: [
        type: :string,
        doc: "Start of time range (ISO 8601). Defaults to now."
      ],
      time_max: [
        type: :string,
        doc: "End of time range (ISO 8601). Optional."
      ]
    ]

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2, get_param: 2, get_param: 3]

  alias Magus.Agents.Signals
  alias Magus.Integrations.Providers.GoogleCalendar.Tools.Helpers, as: CalHelpers
  alias Magus.Integrations.Reactors.RunIntegration

  def display_name, do: "Fetching calendar events..."

  def summarize_output(%{events: events}) when is_list(events) do
    count = length(events)

    if count == 0 do
      "No upcoming events found"
    else
      "Found #{count} event(s)"
    end
  end

  def summarize_output(%{error: error}), do: "Error: #{error}"
  def summarize_output(_), do: "Retrieved events"

  @impl true
  def run(params, context) do
    case validate_context(context, [:user_id]) do
      {:ok, ctx} ->
        calendar_id = get_param(params, :calendar_id, "primary")

        Signals.emit_tool_progress(context, :fetching, %{calendar_id: calendar_id})

        inputs = %{
          user_id: ctx.user_id,
          provider_key: :google_calendar,
          operation: :list_events,
          params: %{
            calendar_id: calendar_id,
            max_results: get_param(params, :max_results, 10),
            time_min: get_param(params, :time_min),
            time_max: get_param(params, :time_max)
          }
        }

        case Reactor.run(RunIntegration, inputs, async?: false) do
          {:ok, %{result: %{events: events}}} ->
            Signals.emit_tool_progress(context, :found_results, %{count: length(events)})
            formatted = format_events(events)
            {:ok, %{events: events, formatted: formatted}}

          {:error, reason} ->
            {:ok, %{error: CalHelpers.format_error(CalHelpers.extract_error(reason))}}
        end

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp format_events(events) do
    events
    |> Enum.map(fn event ->
      time =
        if event.all_day do
          "All day"
        else
          event.start_time
        end

      "- #{event.summary} (#{time})"
    end)
    |> Enum.join("\n")
  end
end
