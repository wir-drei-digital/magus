defmodule Magus.Integrations.Providers.GoogleCalendar.Tools.CreateEvent do
  @moduledoc """
  Tool for creating events in Google Calendar.

  This tool requires the Google Calendar integration to be enabled
  and the `create_event` tool to be enabled for the user.
  """

  use Jido.Action,
    name: "create_calendar_event",
    description: "Create a new event in your Google Calendar",
    schema: [
      summary: [
        type: :string,
        required: true,
        doc: "Title of the event"
      ],
      start_time: [
        type: :string,
        required: true,
        doc: "Start time in ISO 8601 format (e.g., 2024-01-15T10:00:00)"
      ],
      end_time: [
        type: :string,
        required: true,
        doc: "End time in ISO 8601 format (e.g., 2024-01-15T11:00:00)"
      ],
      description: [
        type: :string,
        doc: "Optional description of the event"
      ],
      location: [
        type: :string,
        doc: "Optional location of the event"
      ],
      calendar_id: [
        type: :string,
        default: "primary",
        doc: "Calendar ID to create event in. Use 'primary' for the main calendar."
      ],
      timezone: [
        type: :string,
        doc:
          "Timezone for the event (e.g., 'America/New_York'). Defaults to the user's configured timezone."
      ]
    ]

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2, get_param: 2, get_param: 3]

  alias Magus.Agents.Signals
  alias Magus.Integrations.Providers.GoogleCalendar.Tools.Helpers, as: CalHelpers
  alias Magus.Integrations.Reactors.RunIntegration

  def display_name, do: "Creating calendar event..."

  def summarize_output(%{id: _id, summary: summary}) do
    "Created event: #{summary}"
  end

  def summarize_output(%{error: error}), do: "Error: #{error}"
  def summarize_output(_), do: "Created event"

  @impl true
  def run(params, context) do
    case validate_context(context, [:user_id]) do
      {:ok, ctx} ->
        start_time = get_param(params, :start_time)
        end_time = get_param(params, :end_time)
        summary = get_param(params, :summary)

        # Validate required datetime parameters
        with :ok <- validate_datetime(start_time, "start_time"),
             :ok <- validate_datetime(end_time, "end_time"),
             :ok <- validate_datetime_format_match(start_time, end_time) do
          Signals.emit_tool_progress(context, :creating, %{summary: summary})

          # Use user's timezone as default, falling back to UTC
          user_timezone = get_user_timezone(context)
          param_timezone = get_param(params, :timezone)

          timezone =
            if is_binary(param_timezone) and param_timezone != "" do
              param_timezone
            else
              user_timezone
            end

          inputs = %{
            user_id: ctx.user_id,
            provider_key: :google_calendar,
            operation: :create_event,
            params: %{
              summary: summary,
              start_time: start_time,
              end_time: end_time,
              description: get_param(params, :description),
              location: get_param(params, :location),
              calendar_id: get_param(params, :calendar_id, "primary"),
              timezone: timezone
            }
          }

          case Reactor.run(RunIntegration, inputs, async?: false) do
            {:ok, %{result: event}} ->
              Signals.emit_tool_progress(context, :created, %{summary: event[:summary]})
              {:ok, event}

            {:error, reason} ->
              {:ok, %{error: CalHelpers.format_error(CalHelpers.extract_error(reason))}}
          end
        else
          {:error, message} -> {:ok, %{error: message}}
        end

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  # Extracts user's timezone from context, defaults to UTC
  defp get_user_timezone(context) do
    case context do
      %{user: %{timezone: tz}} when is_binary(tz) and tz != "" -> tz
      _ -> "UTC"
    end
  end

  # Validates that datetime is a non-empty string
  defp validate_datetime(dt, _field_name) when is_binary(dt) and dt != "", do: :ok

  defp validate_datetime(_, field_name),
    do: {:error, "#{field_name} is required and must be a valid datetime string"}

  # Validates that both datetimes use the same format (both date-only or both datetime)
  defp validate_datetime_format_match(start_time, end_time) do
    start_is_date = is_date_only?(start_time)
    end_is_date = is_date_only?(end_time)

    if start_is_date == end_is_date do
      :ok
    else
      {:error,
       "start_time and end_time must use the same format (both dates like '2024-01-15' or both datetimes like '2024-01-15T10:00:00')"}
    end
  end

  defp is_date_only?(dt) when is_binary(dt), do: not String.contains?(dt, "T")
  defp is_date_only?(_), do: false
end
