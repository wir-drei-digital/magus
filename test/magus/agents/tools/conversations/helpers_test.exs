defmodule Magus.Agents.Tools.Conversations.HelpersTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Tools.Conversations.Helpers

  describe "format_datetime/1" do
    test "formats datetime correctly" do
      dt = ~U[2024-06-15 14:30:45Z]
      assert Helpers.format_datetime(dt) == "2024-06-15 14:30"
    end

    test "returns nil for nil input" do
      assert Helpers.format_datetime(nil) == nil
    end
  end

  describe "truncate_text/2" do
    test "returns nil for nil input" do
      assert Helpers.truncate_text(nil, 100) == nil
    end

    test "returns text unchanged if under limit" do
      assert Helpers.truncate_text("short", 100) == "short"
    end

    test "truncates and adds ellipsis if over limit" do
      text = "This is a longer text that should be truncated"
      result = Helpers.truncate_text(text, 20)
      assert result == "This is a longer tex..."
      assert String.length(result) == 23
    end

    test "handles exact length" do
      text = "exact"
      result = Helpers.truncate_text(text, 5)
      assert result == "exact"
    end

    test "handles UTF-8 characters correctly" do
      # Emoji is 1 grapheme but 4 bytes
      text = "Hello 👋 world"
      # Text is 13 graphemes: H-e-l-l-o- -👋- -w-o-r-l-d
      assert String.length(text) == 13

      # Truncate to 8 graphemes should include the emoji
      result = Helpers.truncate_text(text, 8)
      assert result == "Hello 👋 ..."
      assert String.length(result) == 11
    end

    test "handles multi-byte characters without splitting" do
      # Japanese characters are multi-byte
      text = "こんにちは世界"
      assert String.length(text) == 7

      result = Helpers.truncate_text(text, 5)
      assert result == "こんにちは..."
      assert String.length(result) == 8
    end
  end

  describe "format_message/1" do
    test "formats message with all fields" do
      message = %{
        id: "uuid-123",
        role: :user,
        text: "Hello world",
        inserted_at: ~U[2024-06-15 14:30:45Z]
      }

      result = Helpers.format_message(message)

      assert result.id == "uuid-123"
      assert result.role == :user
      assert result.text == "Hello world"
      assert result.created_at == "2024-06-15 14:30"
    end

    test "truncates long text in message" do
      long_text = String.duplicate("a", 600)

      message = %{
        id: "uuid-123",
        role: :user,
        text: long_text,
        inserted_at: ~U[2024-06-15 14:30:45Z]
      }

      result = Helpers.format_message(message)

      # 500 chars + "..." = 503 graphemes
      assert String.length(result.text) == 503
      assert String.ends_with?(result.text, "...")
    end

    test "handles nil text" do
      message = %{
        id: "uuid-123",
        role: :agent,
        text: nil,
        inserted_at: ~U[2024-06-15 14:30:45Z]
      }

      result = Helpers.format_message(message)

      assert result.text == nil
    end
  end
end
