defmodule Magus.Agents.Tools.Jobs.HelpersTest do
  @moduledoc """
  Tests for the shared job tools helper functions.
  """
  use ExUnit.Case, async: true

  alias Magus.Agents.Tools.Jobs.Helpers

  describe "get_context_value/2" do
    test "returns value for atom key" do
      context = %{user_id: "123", conversation_id: "456"}
      assert Helpers.get_context_value(context, :user_id) == "123"
      assert Helpers.get_context_value(context, :conversation_id) == "456"
    end

    test "returns value for string key" do
      context = %{"user_id" => "123", "conversation_id" => "456"}
      assert Helpers.get_context_value(context, :user_id) == "123"
      assert Helpers.get_context_value(context, :conversation_id) == "456"
    end

    test "returns nil for missing key" do
      context = %{user_id: "123"}
      assert Helpers.get_context_value(context, :conversation_id) == nil
    end

    test "returns nil for non-map context" do
      assert Helpers.get_context_value(nil, :user_id) == nil
      assert Helpers.get_context_value("not a map", :user_id) == nil
    end

    test "prefers atom key over string key" do
      # Elixir maps can have both atom and string keys for the same "name"
      context = Map.put(%{user_id: "atom_value"}, "user_id", "string_value")
      assert Helpers.get_context_value(context, :user_id) == "atom_value"
    end
  end

  describe "extract_error_message/1" do
    test "extracts messages from Ash.Error.Invalid" do
      error = %Ash.Error.Invalid{
        errors: [
          %{message: "is required"},
          %{message: "must be unique"}
        ]
      }

      assert Helpers.extract_error_message(error) == "is required; must be unique"
    end

    test "handles single error" do
      error = %Ash.Error.Invalid{
        errors: [%{message: "is invalid"}]
      }

      assert Helpers.extract_error_message(error) == "is invalid"
    end

    test "handles empty errors" do
      error = %Ash.Error.Invalid{errors: []}
      assert Helpers.extract_error_message(error) == ""
    end

    test "inspects non-Ash errors" do
      assert Helpers.extract_error_message(:some_error) == ":some_error"
      assert Helpers.extract_error_message("string error") == "\"string error\""
    end
  end

  describe "format_datetime/2" do
    test "formats datetime in UTC" do
      {:ok, dt, _} = DateTime.from_iso8601("2024-03-15T14:30:00Z")
      assert Helpers.format_datetime(dt, "UTC") == "2024-03-15 14:30 UTC"
    end

    test "formats datetime with nil timezone defaults to UTC" do
      {:ok, dt, _} = DateTime.from_iso8601("2024-03-15T14:30:00Z")
      assert Helpers.format_datetime(dt, nil) == "2024-03-15 14:30 UTC"
    end

    test "returns nil for nil datetime" do
      assert Helpers.format_datetime(nil, "UTC") == nil
    end

    test "handles invalid timezone gracefully" do
      {:ok, dt, _} = DateTime.from_iso8601("2024-03-15T14:30:00Z")
      # Should fall back to UTC if timezone is invalid
      result = Helpers.format_datetime(dt, "Invalid/Timezone")
      assert result =~ "2024-03-15 14:30"
    end
  end

  describe "parse_datetime/1" do
    test "parses valid ISO8601 string" do
      result = Helpers.parse_datetime("2024-03-15T14:30:00Z")
      assert %DateTime{} = result
      assert result.year == 2024
      assert result.month == 3
      assert result.day == 15
      assert result.hour == 14
      assert result.minute == 30
    end

    test "returns nil for nil input" do
      assert Helpers.parse_datetime(nil) == nil
    end

    test "returns nil for invalid string" do
      assert Helpers.parse_datetime("invalid") == nil
      assert Helpers.parse_datetime("2024-13-45") == nil
    end

    test "handles datetime with offset" do
      result = Helpers.parse_datetime("2024-03-15T14:30:00+05:00")
      assert %DateTime{} = result
    end
  end

  describe "ai_actor/0" do
    test "returns AiAgent struct" do
      assert %Magus.Agents.Support.AiAgent{} = Helpers.ai_actor()
    end
  end

  describe "validate_context/2" do
    test "returns ok with extracted values when all keys present" do
      context = %{user_id: "123", conversation_id: "456", folder_id: "789"}

      assert {:ok, extracted} = Helpers.validate_context(context, [:user_id, :conversation_id])
      assert extracted.user_id == "123"
      assert extracted.conversation_id == "456"
    end

    test "returns error when keys are missing" do
      context = %{user_id: "123"}

      assert {:error, message} = Helpers.validate_context(context, [:user_id, :conversation_id])
      assert message =~ "Missing required context"
      assert message =~ "conversation_id"
    end

    test "returns error listing all missing keys" do
      context = %{}

      assert {:error, message} =
               Helpers.validate_context(context, [:user_id, :conversation_id])

      assert message =~ "user_id"
      assert message =~ "conversation_id"
    end

    test "works with string keys in context" do
      context = %{"user_id" => "123", "conversation_id" => "456"}

      assert {:ok, extracted} = Helpers.validate_context(context, [:user_id, :conversation_id])
      assert extracted.user_id == "123"
      assert extracted.conversation_id == "456"
    end
  end

  describe "format_schedule/1" do
    test "formats cron schedule" do
      job = %{
        schedule_type: :cron,
        cron_expression: "0 14 * * *",
        cron_expression_local: "0 9 * * *",
        user_timezone: "America/New_York",
        scheduled_at: nil
      }

      result = Helpers.format_schedule(job)
      assert result == "0 9 * * * (America/New_York)"
    end

    test "formats cron schedule without local expression" do
      job = %{
        schedule_type: :cron,
        cron_expression: "0 14 * * *",
        cron_expression_local: nil,
        user_timezone: "UTC",
        scheduled_at: nil
      }

      result = Helpers.format_schedule(job)
      assert result == "0 14 * * * (UTC)"
    end

    test "formats one-time schedule" do
      {:ok, dt, _} = DateTime.from_iso8601("2024-03-15T14:30:00Z")

      job = %{
        schedule_type: :one_time,
        cron_expression: nil,
        cron_expression_local: nil,
        user_timezone: "UTC",
        scheduled_at: dt
      }

      result = Helpers.format_schedule(job)
      assert result =~ "Once at"
      assert result =~ "2024-03-15"
    end
  end

  describe "get_timezone/2" do
    test "returns timezone from job's user_timezone" do
      job = %{user_timezone: "America/New_York"}
      assert Helpers.get_timezone(%{}, job) == "America/New_York"
    end

    test "returns UTC when job has no timezone" do
      job = %{user_timezone: nil}
      assert Helpers.get_timezone(%{}, job) == "UTC"
    end

    test "returns UTC when job has empty timezone" do
      job = %{user_timezone: ""}
      assert Helpers.get_timezone(%{}, job) == "UTC"
    end

    test "returns UTC when no job provided" do
      assert Helpers.get_timezone(%{}, nil) == "UTC"
    end

    test "context is ignored, only job timezone is used" do
      # Context user_id is all we have, so job timezone is the source of truth
      context = %{user_id: "123"}
      job = %{user_timezone: "Europe/London"}
      assert Helpers.get_timezone(context, job) == "Europe/London"
    end
  end

  describe "max_jobs_per_user/0" do
    test "returns configured value or default" do
      # Should return the configured value (10 from config) or default
      result = Helpers.max_jobs_per_user()
      assert is_integer(result)
      assert result > 0
    end
  end
end
