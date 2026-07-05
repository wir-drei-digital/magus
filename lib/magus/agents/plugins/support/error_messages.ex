defmodule Magus.Agents.Plugins.Support.ErrorMessages do
  @moduledoc """
  Translates internal agent errors into user-friendly messages and persists
  them as event messages in the conversation.

  This module bridges the gap between ephemeral PubSub error broadcasts and
  persisted conversation history: callers can create a visible event message
  so the user understands what happened even after a page refresh.
  """

  require Logger

  use Gettext, backend: MagusWeb.Gettext

  @doc """
  Return a user-friendly error string for the given error type and detail.

  ## Error types

    * `:limit_exceeded` — usage plan limit hit (passes through the exception message)
    * `:request_failed` — LLM or worker failure (timeout, HTTP errors, etc.)
    * `:busy` — agent is already processing a request
    * anything else — generic fallback
  """
  @spec format_user_friendly_error(atom(), term()) :: String.t()
  def format_user_friendly_error(:broken_model_selection, error) when is_binary(error), do: error

  def format_user_friendly_error(:limit_exceeded, error) when is_binary(error), do: error

  def format_user_friendly_error(:limit_exceeded, %Magus.Usage.PolicyError{} = error) do
    Magus.Usage.PolicyErrorMessage.message(error)
  end

  def format_user_friendly_error(:limit_exceeded, error) when is_exception(error) do
    Exception.message(error)
  end

  def format_user_friendly_error(:limit_exceeded, error) do
    inspect(error)
  end

  def format_user_friendly_error(:request_failed, {:react_worker_exit, {:timeout, _}}) do
    gettext("The request timed out. Please try again.")
  end

  def format_user_friendly_error(:request_failed, {:react_worker_exit, %{status: status}})
      when status in [502, 503, 529] do
    gettext("The AI model is temporarily unavailable. Please try again in a moment.")
  end

  # Context window exceeded (e.g. large PDF with a small-context model)
  def format_user_friendly_error(:request_failed, %{status: 400, reason: reason})
      when is_binary(reason) do
    if String.contains?(reason, "context length") or
         String.contains?(reason, "too many tokens") do
      gettext(
        "The content exceeds the selected model's context window. Try a model with a larger context or shorten the input."
      )
    else
      gettext("The model rejected the request. Please try again or switch models.")
    end
  end

  # Rate limiting
  def format_user_friendly_error(:request_failed, %{status: 429}) do
    gettext("Rate limit reached. Please wait a moment and try again.")
  end

  # Model unavailable (direct error, not wrapped in react_worker_exit)
  def format_user_friendly_error(:request_failed, %{status: status})
      when status in [502, 503, 529] do
    gettext("The AI model is temporarily unavailable. Please try again in a moment.")
  end

  def format_user_friendly_error(:request_failed, _error) do
    gettext("Something went wrong while generating a response. Please try again.")
  end

  def format_user_friendly_error(:busy, _error) do
    gettext("The assistant is still processing your previous request. Please wait a moment.")
  end

  def format_user_friendly_error(_error_type, _error) do
    gettext("An unexpected error occurred. Please try again.")
  end

  @doc """
  Create a persisted event message in the conversation with a user-friendly
  error description.

  Returns `nil` on any failure (logs a warning instead of crashing).
  """
  @spec create_error_event(String.t(), atom(), term()) :: nil
  def create_error_event(conversation_id, error_type, error) do
    text = format_user_friendly_error(error_type, error)
    Magus.Chat.create_event_message!(text, conversation_id, authorize?: false)
    nil
  rescue
    exception ->
      Logger.warning(
        "Failed to persist error event for conversation #{conversation_id}: #{Exception.message(exception)}"
      )

      nil
  end
end
