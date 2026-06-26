defmodule Magus.Integrations.Providers.GoogleCalendar do
  @moduledoc """
  Google Calendar API v3 provider.

  Provides OAuth2 authentication and calendar operations.

  ## Tools

  This provider includes tools that can be enabled per-user:
  - `list_events` - List upcoming calendar events
  - `create_event` - Create a new calendar event
  - `update_event` - Update an existing calendar event
  - `delete_event` - Delete a calendar event

  ## API Reference

  https://developers.google.com/workspace/calendar/api/v3/reference
  """

  @behaviour Magus.Integrations.Providers.Behaviour

  alias Magus.Integrations.Providers.GoogleCalendar.Tools.{
    ListEvents,
    CreateEvent,
    UpdateEvent,
    DeleteEvent
  }

  @base_url "https://www.googleapis.com/calendar/v3"

  @impl true
  def key, do: :google_calendar

  @impl true
  def name, do: "Google Calendar"

  @impl true
  def description, do: "View and manage your Google Calendar events"

  @impl true
  def auth_type, do: :oauth2

  @impl true
  def oauth_config do
    %{
      authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
      token_url: "https://oauth2.googleapis.com/token",
      scopes: ["https://www.googleapis.com/auth/calendar"],
      client_id: Application.get_env(:magus, :google_client_id),
      client_secret: Application.get_env(:magus, :google_client_secret)
    }
  end

  @impl true
  def source_type, do: :tool_provider

  @impl true
  def operations,
    do: [:list_calendars, :list_events, :get_event, :create_event, :update_event, :delete_event]

  @impl true
  def tools do
    [
      %{
        key: :list_events,
        module: ListEvents,
        name: "List Calendar Events",
        description: "Retrieve upcoming events from Google Calendar"
      },
      %{
        key: :create_event,
        module: CreateEvent,
        name: "Create Calendar Event",
        description: "Create a new event in Google Calendar"
      },
      %{
        key: :update_event,
        module: UpdateEvent,
        name: "Update Calendar Event",
        description: "Update an existing event in Google Calendar"
      },
      %{
        key: :delete_event,
        module: DeleteEvent,
        name: "Delete Calendar Event",
        description: "Delete an event from Google Calendar"
      }
    ]
  end

  @impl true
  def requires_admin?, do: true

  @impl true
  def execute(:list_calendars, credentials, _params) do
    get(credentials, "/users/me/calendarList")
    |> transform_calendars()
  end

  def execute(:list_events, credentials, params) do
    calendar_id = params[:calendar_id] || "primary"

    query =
      %{
        timeMin: params[:time_min] || DateTime.utc_now() |> DateTime.to_iso8601(),
        timeMax: params[:time_max],
        maxResults: params[:max_results] || 50,
        singleEvents: true,
        orderBy: "startTime"
      }
      |> compact()

    get(credentials, "/calendars/#{encode(calendar_id)}/events", query)
    |> transform_events()
  end

  def execute(:get_event, credentials, params) do
    calendar_id = params[:calendar_id] || "primary"
    event_id = params.event_id

    get(credentials, "/calendars/#{encode(calendar_id)}/events/#{event_id}")
    |> transform_event()
  end

  def execute(:create_event, credentials, params) do
    calendar_id = params[:calendar_id] || "primary"

    body =
      %{
        summary: params.summary,
        description: params[:description],
        location: params[:location],
        start: format_datetime(params.start_time, params[:timezone]),
        end: format_datetime(params.end_time, params[:timezone]),
        attendees: format_attendees(params[:attendees])
      }
      |> compact()

    post(credentials, "/calendars/#{encode(calendar_id)}/events", body)
    |> transform_event()
  end

  def execute(:update_event, credentials, params) do
    calendar_id = params[:calendar_id] || "primary"
    event_id = params.event_id

    body =
      %{
        summary: params[:summary],
        description: params[:description],
        location: params[:location],
        start: params[:start_time] && format_datetime(params.start_time, params[:timezone]),
        end: params[:end_time] && format_datetime(params.end_time, params[:timezone])
      }
      |> compact()

    patch(credentials, "/calendars/#{encode(calendar_id)}/events/#{event_id}", body)
    |> transform_event()
  end

  def execute(:delete_event, credentials, params) do
    calendar_id = params[:calendar_id] || "primary"
    event_id = params.event_id

    delete(credentials, "/calendars/#{encode(calendar_id)}/events/#{event_id}")
  end

  def execute(operation, _credentials, _params) do
    {:error, "Unsupported operation: #{operation}"}
  end

  @doc """
  Refresh an expired OAuth token using the refresh_token.

  Returns new credentials map with updated access_token and expires_at.
  """
  @spec refresh_token(map()) :: {:ok, map()} | {:error, term()}
  def refresh_token(credentials) do
    refresh_token = credentials["refresh_token"]

    if is_nil(refresh_token) do
      {:error, :no_refresh_token}
    else
      config = oauth_config()

      body = %{
        grant_type: "refresh_token",
        refresh_token: refresh_token,
        client_id: config.client_id,
        client_secret: config.client_secret
      }

      case Req.post("https://oauth2.googleapis.com/token", form: Map.to_list(body)) do
        {:ok, %{status: 200, body: tokens}} ->
          # Merge new tokens with existing credentials (keeps refresh_token if not returned)
          new_credentials = %{
            "access_token" => tokens["access_token"],
            "refresh_token" => tokens["refresh_token"] || refresh_token,
            "expires_at" => calculate_expiry(tokens["expires_in"])
          }

          {:ok, new_credentials}

        {:ok, %{status: 400, body: %{"error" => "invalid_grant"}}} ->
          # Refresh token has been revoked or expired
          {:error, :refresh_token_revoked}

        {:ok, %{status: status, body: body}} ->
          {:error, {:token_refresh_failed, status, body}}

        {:error, reason} ->
          {:error, {:network_error, reason}}
      end
    end
  end

  defp calculate_expiry(expires_in) when is_integer(expires_in) do
    DateTime.utc_now()
    |> DateTime.add(expires_in, :second)
    |> DateTime.to_iso8601()
  end

  defp calculate_expiry(_), do: nil

  # Transform API responses to our format

  defp transform_calendars({:ok, %{"items" => items}}) do
    calendars =
      Enum.map(items, fn cal ->
        %{
          id: cal["id"],
          name: cal["summary"],
          primary: cal["primary"] || false,
          access_role: cal["accessRole"],
          color: cal["backgroundColor"]
        }
      end)

    {:ok, %{calendars: calendars}}
  end

  defp transform_calendars(error), do: error

  defp transform_events({:ok, %{"items" => items}}) do
    events = Enum.map(items, &transform_single_event/1)
    {:ok, %{events: events}}
  end

  defp transform_events(error), do: error

  defp transform_event({:ok, event}), do: {:ok, transform_single_event(event)}
  defp transform_event(error), do: error

  defp transform_single_event(event) do
    %{
      id: event["id"],
      summary: event["summary"],
      description: event["description"],
      location: event["location"],
      start_time: parse_event_time(event["start"]),
      end_time: parse_event_time(event["end"]),
      status: event["status"],
      html_link: event["htmlLink"],
      attendees: parse_attendees(event["attendees"]),
      all_day: is_all_day?(event)
    }
  end

  defp parse_event_time(%{"dateTime" => dt}), do: dt
  defp parse_event_time(%{"date" => d}), do: d
  defp parse_event_time(_), do: nil

  defp is_all_day?(%{"start" => %{"date" => _}}), do: true
  defp is_all_day?(_), do: false

  defp parse_attendees(nil), do: []

  defp parse_attendees(attendees) do
    Enum.map(attendees, fn a ->
      %{email: a["email"], name: a["displayName"], status: a["responseStatus"]}
    end)
  end

  defp format_datetime(datetime, timezone) do
    if is_date_only?(datetime) do
      %{date: datetime}
    else
      %{dateTime: datetime, timeZone: timezone || "UTC"}
    end
  end

  defp is_date_only?(dt) when is_binary(dt), do: not String.contains?(dt, "T")
  defp is_date_only?(_), do: false

  defp format_attendees(nil), do: nil
  defp format_attendees(emails), do: Enum.map(emails, &%{email: &1})

  defp compact(map) do
    map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
  end

  defp encode(id), do: URI.encode(id, &URI.char_unreserved?/1)

  # HTTP helpers

  defp get(credentials, path, query \\ %{}) do
    request(:get, credentials, path, params: query)
  end

  defp post(credentials, path, body) do
    request(:post, credentials, path, json: body)
  end

  defp patch(credentials, path, body) do
    request(:patch, credentials, path, json: body)
  end

  defp delete(credentials, path) do
    request(:delete, credentials, path, [])
  end

  defp request(method, credentials, path, opts) do
    url = @base_url <> path
    # Credentials are stored with string keys from OAuth callback
    access_token = credentials["access_token"]
    headers = [{"authorization", "Bearer #{access_token}"}]

    case Req.request([method: method, url: url, headers: headers] ++ opts) do
      {:ok, %{status: 204}} ->
        {:ok, %{deleted: true}}

      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: 401}} ->
        {:error, :token_expired}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, message: body["error"]["message"]}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
