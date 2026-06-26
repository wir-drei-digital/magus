defmodule Magus.Integrations.Providers.GoogleCalendarTest do
  use ExUnit.Case, async: true

  alias Magus.Integrations.Providers.GoogleCalendar

  describe "provider metadata" do
    test "returns correct key" do
      assert GoogleCalendar.key() == :google_calendar
    end

    test "returns correct name" do
      assert GoogleCalendar.name() == "Google Calendar"
    end

    test "returns correct auth type" do
      assert GoogleCalendar.auth_type() == :oauth2
    end

    test "source type is tool_provider" do
      assert GoogleCalendar.source_type() == :tool_provider
    end

    test "defines all operations" do
      ops = GoogleCalendar.operations()
      assert :list_calendars in ops
      assert :list_events in ops
      assert :get_event in ops
      assert :create_event in ops
      assert :update_event in ops
      assert :delete_event in ops
    end
  end

  describe "oauth_config/0" do
    test "returns required OAuth2 fields" do
      config = GoogleCalendar.oauth_config()

      assert config.authorize_url == "https://accounts.google.com/o/oauth2/v2/auth"
      assert config.token_url == "https://oauth2.googleapis.com/token"
      assert is_list(config.scopes)
      assert "https://www.googleapis.com/auth/calendar" in config.scopes
      assert Map.has_key?(config, :client_id)
      assert Map.has_key?(config, :client_secret)
    end
  end

  describe "tools/0" do
    test "returns all four tools" do
      tools = GoogleCalendar.tools()
      assert length(tools) == 4
    end

    test "each tool has required keys" do
      for tool <- GoogleCalendar.tools() do
        assert Map.has_key?(tool, :key)
        assert Map.has_key?(tool, :module)
        assert Map.has_key?(tool, :name)
        assert Map.has_key?(tool, :description)
        assert is_atom(tool.key)
        assert is_atom(tool.module)
        assert is_binary(tool.name)
        assert is_binary(tool.description)
      end
    end

    test "tool keys match provider operations" do
      tool_keys = GoogleCalendar.tools() |> Enum.map(& &1.key) |> MapSet.new()
      operations = MapSet.new(GoogleCalendar.operations())
      # All tool keys should be valid operations
      assert MapSet.subset?(tool_keys, operations)
    end

    test "includes list_events tool" do
      tools = GoogleCalendar.tools()
      tool = Enum.find(tools, &(&1.key == :list_events))
      assert tool.module == Magus.Integrations.Providers.GoogleCalendar.Tools.ListEvents
    end

    test "includes create_event tool" do
      tools = GoogleCalendar.tools()
      tool = Enum.find(tools, &(&1.key == :create_event))
      assert tool.module == Magus.Integrations.Providers.GoogleCalendar.Tools.CreateEvent
    end

    test "includes update_event tool" do
      tools = GoogleCalendar.tools()
      tool = Enum.find(tools, &(&1.key == :update_event))
      assert tool.module == Magus.Integrations.Providers.GoogleCalendar.Tools.UpdateEvent
    end

    test "includes delete_event tool" do
      tools = GoogleCalendar.tools()
      tool = Enum.find(tools, &(&1.key == :delete_event))
      assert tool.module == Magus.Integrations.Providers.GoogleCalendar.Tools.DeleteEvent
    end
  end

  describe "execute/3 error handling" do
    test "returns error for unsupported operation" do
      result = GoogleCalendar.execute(:unsupported_op, %{}, %{})
      assert {:error, "Unsupported operation: unsupported_op"} = result
    end
  end

  describe "refresh_token/1" do
    test "returns error when no refresh_token in credentials" do
      result = GoogleCalendar.refresh_token(%{})
      assert {:error, :no_refresh_token} = result
    end

    test "returns error when refresh_token is nil" do
      result = GoogleCalendar.refresh_token(%{"refresh_token" => nil})
      assert {:error, :no_refresh_token} = result
    end
  end
end
