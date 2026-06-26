defmodule Magus.Integrations.Providers.GoogleCalendar.Tools.UpdateEvent do
  @moduledoc """
  Tool for updating an existing event in Google Calendar.

  This tool requires the Google Calendar integration to be enabled
  and the `update_event` tool to be enabled for the user.
  """

  use Jido.Action,
    name: "update_calendar_event",
    description: "Update an existing event in your Google Calendar",
    schema: [
      event_id: [
        type: :string,
        required: true,
        doc: "The ID of the event to update"
      ],
      summary: [
        type: :string,
        doc: "New title for the event"
      ],
      start_time: [
        type: :string,
        doc: "New start time in ISO 8601 format (e.g., 2024-01-15T10:00:00)"
      ],
      end_time: [
        type: :string,
        doc: "New end time in ISO 8601 format (e.g., 2024-01-15T11:00:00)"
      ],
      description: [
        type: :string,
        doc: "New description for the event"
      ],
      location: [
        type: :string,
        doc: "New location for the event"
      ],
      calendar_id: [
        type: :string,
        default: "primary",
        doc: "Calendar ID containing the event. Use 'primary' for the main calendar."
      ],
      timezone: [
        type: :string,
        doc:
          "Timezone for the event times (e.g., 'America/New_York'). Defaults to the user's configured timezone."
      ]
    ]

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2, get_param: 2, get_param: 3]

  alias Magus.Agents.Signals
  alias Magus.Integrations.Providers.GoogleCalendar.Tools.Helpers, as: CalHelpers
  alias Magus.Integrations.Reactors.RunIntegration

  def display_name, do: "Updating calendar event..."

  def summarize_output(%{summary: summary}) do
    "Updated event: #{summary}"
  end

  def summarize_output(%{error: error}), do: "Error: #{error}"
  def summarize_output(_), do: "Updated event"

  @impl true
  def run(params, context) do
    # Guard against malformed params from truncated tool calls
    if not is_map(params) do
      {:ok, %{error: "Invalid parameters received"}}
    else
      do_run(params, context)
    end
  end

  defp do_run(params, context) do
    case validate_context(context, [:user_id]) do
      {:ok, ctx} ->
        start_time = get_param(params, :start_time)
        end_time = get_param(params, :end_time)

        cond do
          # Both provided - validate they use same format
          start_time && end_time ->
            case validate_datetime_format_match(start_time, end_time) do
              :ok ->
                do_update(params, context, ctx, start_time, end_time)

              {:error, message} ->
                {:ok, %{error: message}}
            end

          # One provided but not the other
          (start_time && !end_time) || (!start_time && end_time) ->
            {:ok,
             %{error: "Both start_time and end_time must be provided when updating event times"}}

          # Neither provided - that's fine for updates
          true ->
            do_update(params, context, ctx, nil, nil)
        end

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp do_update(params, context, ctx, start_time, end_time) do
    event_id = get_param(params, :event_id)
    Signals.emit_tool_progress(context, :updating, %{event_id: event_id})

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
      operation: :update_event,
      params: %{
        event_id: event_id,
        summary: get_param(params, :summary),
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
        Signals.emit_tool_progress(context, :updated, %{summary: event[:summary]})
        {:ok, event}

      {:error, reason} ->
        {:ok, %{error: CalHelpers.format_error(CalHelpers.extract_error(reason))}}
    end
  end

  # Extracts user's timezone from context, defaults to UTC
  defp get_user_timezone(context) do
    case context do
      %{user: %{timezone: tz}} when is_binary(tz) and tz != "" -> tz
      _ -> "UTC"
    end
  end

  # Validates that both datetimes use the same format (both date-only or both datetime)
  defp validate_datetime_format_match(start_time, end_time) do
    start_is_date = is_date_only?(start_time)
    end_is_date = is_date_only?(end_time)

    if start_is_date == end_is_date do
      :ok
    else
      {:error, "start_time and end_time must use the same format (both dates or both datetimes)"}
    end
  end

  defp is_date_only?(dt) when is_binary(dt), do: not String.contains?(dt, "T")
  defp is_date_only?(_), do: false
end
