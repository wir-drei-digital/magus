defmodule Magus.Agents.Tools.Conversations.Helpers do
  @moduledoc """
  Shared helper functions for conversation history tools.

  Provides common functionality for formatting messages and handling context
  validation, following the same patterns as memory and job tools.
  """

  # Re-export shared helpers for convenience
  defdelegate get_context_value(context, key), to: Magus.Agents.Tools.Helpers
  defdelegate validate_context(context, required_keys), to: Magus.Agents.Tools.Helpers
  defdelegate extract_error_message(error), to: Magus.Agents.Tools.Helpers
  defdelegate ai_actor(), to: Magus.Agents.Tools.Helpers

  @doc """
  Formats a message for tool output, including truncation of long text.

  ## Examples

      iex> format_message(%{id: "123", role: :user, text: "Hello", inserted_at: ~U[2024-01-15 10:30:00Z]})
      %{id: "123", role: :user, text: "Hello", created_at: "2024-01-15 10:30"}
  """
  @spec format_message(map()) :: map()
  def format_message(message) do
    %{
      id: message.id,
      role: message.role,
      text: truncate_text(message.text, 500),
      created_at: format_datetime(message.inserted_at)
    }
  end

  @doc """
  Formats a datetime for display.

  ## Examples

      iex> format_datetime(~U[2024-01-15 10:30:00Z])
      "2024-01-15 10:30"

      iex> format_datetime(nil)
      nil
  """
  @spec format_datetime(DateTime.t() | nil) :: String.t() | nil
  def format_datetime(nil), do: nil
  def format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  @doc """
  Truncates text to a maximum number of graphemes, adding ellipsis if truncated.

  Uses grapheme count (not byte size) for consistent behavior with UTF-8 text.

  ## Examples

      iex> truncate_text("short", 100)
      "short"

      iex> truncate_text("This is a longer text", 10)
      "This is a ..."

      iex> truncate_text(nil, 100)
      nil
  """
  @spec truncate_text(String.t() | nil, pos_integer()) :: String.t() | nil
  def truncate_text(nil, _max_length), do: nil

  def truncate_text(text, max_length) do
    if String.length(text) <= max_length do
      text
    else
      String.slice(text, 0, max_length) <> "..."
    end
  end
end
