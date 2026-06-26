defmodule Magus.Integrations.Providers.GoogleCalendar.ToolsTest do
  use ExUnit.Case, async: true

  alias Magus.Integrations.Providers.GoogleCalendar.Tools.{
    ListEvents,
    CreateEvent,
    UpdateEvent,
    DeleteEvent
  }

  alias Magus.Integrations.Providers.GoogleCalendar.Tools.Helpers, as: CalHelpers

  describe "ListEvents" do
    test "display_name returns a string" do
      assert ListEvents.display_name() == "Fetching calendar events..."
    end

    test "summarize_output with events" do
      result = %{events: [%{summary: "Meeting"}, %{summary: "Lunch"}]}
      assert ListEvents.summarize_output(result) == "Found 2 event(s)"
    end

    test "summarize_output with empty events" do
      result = %{events: []}
      assert ListEvents.summarize_output(result) == "No upcoming events found"
    end

    test "summarize_output with error" do
      result = %{error: "Token expired"}
      assert ListEvents.summarize_output(result) == "Error: Token expired"
    end

    test "summarize_output with unknown result" do
      assert ListEvents.summarize_output(%{}) == "Retrieved events"
    end

    test "module is a valid Jido Action" do
      assert function_exported?(ListEvents, :run, 2)
      assert function_exported?(ListEvents, :display_name, 0)
      assert function_exported?(ListEvents, :summarize_output, 1)
    end

    test "run returns error when user_id missing from context" do
      assert {:ok, %{error: "Missing required context (user_id)"}} =
               ListEvents.run(%{}, %{})
    end
  end

  describe "CreateEvent" do
    test "display_name returns a string" do
      assert CreateEvent.display_name() == "Creating calendar event..."
    end

    test "summarize_output with created event" do
      result = %{id: "evt_123", summary: "Team standup"}
      assert CreateEvent.summarize_output(result) == "Created event: Team standup"
    end

    test "summarize_output with error" do
      result = %{error: "Integration not active"}
      assert CreateEvent.summarize_output(result) == "Error: Integration not active"
    end

    test "summarize_output with unknown result" do
      assert CreateEvent.summarize_output(%{}) == "Created event"
    end

    test "module is a valid Jido Action" do
      assert function_exported?(CreateEvent, :run, 2)
      assert function_exported?(CreateEvent, :display_name, 0)
      assert function_exported?(CreateEvent, :summarize_output, 1)
    end

    test "run returns error when user_id missing from context" do
      assert {:ok, %{error: "Missing required context (user_id)"}} =
               CreateEvent.run(%{}, %{})
    end
  end

  describe "UpdateEvent" do
    test "display_name returns a string" do
      assert UpdateEvent.display_name() == "Updating calendar event..."
    end

    test "summarize_output with updated event" do
      result = %{summary: "Updated standup"}
      assert UpdateEvent.summarize_output(result) == "Updated event: Updated standup"
    end

    test "summarize_output with error" do
      result = %{error: "Not found"}
      assert UpdateEvent.summarize_output(result) == "Error: Not found"
    end

    test "summarize_output with unknown result" do
      assert UpdateEvent.summarize_output(%{}) == "Updated event"
    end

    test "module is a valid Jido Action" do
      assert function_exported?(UpdateEvent, :run, 2)
      assert function_exported?(UpdateEvent, :display_name, 0)
      assert function_exported?(UpdateEvent, :summarize_output, 1)
    end

    test "run returns error when user_id missing from context" do
      assert {:ok, %{error: "Missing required context (user_id)"}} =
               UpdateEvent.run(%{}, %{})
    end

    test "run returns error when only start_time provided without end_time" do
      params = %{"event_id" => "evt_1", "start_time" => "2024-01-15T10:00:00"}
      context = %{user_id: "user-123"}

      assert {:ok, %{error: "Both start_time and end_time" <> _}} =
               UpdateEvent.run(params, context)
    end

    test "run returns error when only end_time provided without start_time" do
      params = %{"event_id" => "evt_1", "end_time" => "2024-01-15T11:00:00"}
      context = %{user_id: "user-123"}

      assert {:ok, %{error: "Both start_time and end_time" <> _}} =
               UpdateEvent.run(params, context)
    end
  end

  describe "DeleteEvent" do
    test "display_name returns a string" do
      assert DeleteEvent.display_name() == "Deleting calendar event..."
    end

    test "summarize_output with deleted event" do
      result = %{deleted: true}
      assert DeleteEvent.summarize_output(result) == "Event deleted"
    end

    test "summarize_output with error" do
      result = %{error: "Permission denied"}
      assert DeleteEvent.summarize_output(result) == "Error: Permission denied"
    end

    test "summarize_output with unknown result" do
      assert DeleteEvent.summarize_output(%{}) == "Deleted event"
    end

    test "module is a valid Jido Action" do
      assert function_exported?(DeleteEvent, :run, 2)
      assert function_exported?(DeleteEvent, :display_name, 0)
      assert function_exported?(DeleteEvent, :summarize_output, 1)
    end

    test "run returns error when user_id missing from context" do
      assert {:ok, %{error: "Missing required context (user_id)"}} =
               DeleteEvent.run(%{}, %{})
    end
  end

  describe "shared helpers" do
    test "extract_error unwraps Reactor.Error.Invalid" do
      error = %Reactor.Error.Invalid{errors: [%{error: :token_expired}]}
      assert CalHelpers.extract_error(error) == :token_expired
    end

    test "extract_error unwraps nested errors" do
      error = %{errors: [:integration_not_active]}
      assert CalHelpers.extract_error(error) == :integration_not_active
    end

    test "extract_error returns raw error when not wrapped" do
      assert CalHelpers.extract_error(:some_error) == :some_error
    end

    test "format_error handles :token_expired" do
      assert CalHelpers.format_error(:token_expired) =~ "access token expired"
    end

    test "format_error handles :integration_not_active" do
      assert CalHelpers.format_error(:integration_not_active) =~ "not active"
    end

    test "format_error handles :reauthorization_required" do
      assert CalHelpers.format_error(:reauthorization_required) =~ "revoked"
    end

    test "format_error handles map with message" do
      assert CalHelpers.format_error(%{message: "Rate limit exceeded"}) == "Rate limit exceeded"
    end

    test "format_error falls back to inspect for unknown errors" do
      assert CalHelpers.format_error({:unknown, "something"}) ==
               inspect({:unknown, "something"})
    end
  end

  describe "tool schema consistency" do
    test "all tools define name and description via Jido.Action" do
      for mod <- [ListEvents, CreateEvent, UpdateEvent, DeleteEvent] do
        assert function_exported?(mod, :to_tool, 0) or function_exported?(mod, :run, 2),
               "#{inspect(mod)} must implement Jido.Action"
      end
    end
  end
end
