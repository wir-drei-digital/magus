defmodule Magus.Agents.Context.BuilderCurrentTimeTest do
  @moduledoc """
  DB-free unit tests for `Builder.prepend_current_time/2`.

  The live clock was moved out of the (cache-stable) system prompt and onto the
  current user turn. This covers the pure text/timezone-formatting logic of that
  helper in isolation, without building a conversation from the database.
  """
  use ExUnit.Case, async: true

  alias Magus.Agents.Context.Builder

  describe "prepend_current_time/2" do
    test "prepends a current-time line to the text" do
      result = Builder.prepend_current_time("hello", %{timezone: "Europe/Zurich"})

      assert String.starts_with?(result, "[Current time: ")
      # The original text is preserved after the time line + blank line.
      assert String.ends_with?(result, "\n\nhello")
      assert String.contains?(result, "hello")
    end

    test "uses the given timezone name" do
      result = Builder.prepend_current_time("hi", %{timezone: "Europe/Zurich"})

      assert String.contains?(result, "Timezone: Europe/Zurich.")
    end

    test "includes both a local time and a UTC time" do
      result = Builder.prepend_current_time("hi", %{timezone: "Europe/Zurich"})

      # Local timestamp (YYYY-MM-DD HH:MM ...) and an explicit UTC component.
      assert Regex.match?(~r/\[Current time: \d{4}-\d{2}-\d{2} \d{2}:\d{2}/, result)
      assert Regex.match?(~r/\(UTC \d{2}:\d{2}\)/, result)
    end

    test "falls back to UTC for a nil user" do
      result = Builder.prepend_current_time("hi", nil)

      assert String.contains?(result, "Timezone: UTC.")
    end

    test "falls back to UTC for a user with nil timezone" do
      result = Builder.prepend_current_time("hi", %{timezone: nil})

      assert String.contains?(result, "Timezone: UTC.")
    end

    test "falls back to UTC for an empty timezone" do
      result = Builder.prepend_current_time("hi", %{timezone: ""})

      assert String.contains?(result, "Timezone: UTC.")
    end

    test "falls back to UTC for an invalid timezone" do
      result = Builder.prepend_current_time("hi", %{timezone: "Invalid/Timezone"})

      assert String.contains?(result, "Timezone: UTC.")
      assert Regex.match?(~r/\[Current time: \d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC/, result)
    end
  end
end
