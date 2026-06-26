defmodule Magus.Integrations.Providers.GoogleCalendar.Tools.Helpers do
  @moduledoc false

  @doc """
  Extract the root error from a nested Reactor error.
  """
  def extract_error(%Reactor.Error.Invalid{errors: [%{error: error} | _]}),
    do: extract_error(error)

  def extract_error(%{errors: [error | _]}), do: extract_error(error)
  def extract_error(error), do: error

  @doc """
  Format an integration error into a user-friendly message.
  """
  def format_error(:token_expired),
    do: "Google Calendar access token expired. Please reconnect."

  def format_error(:integration_not_active),
    do: "Google Calendar integration is not active."

  def format_error(:reauthorization_required),
    do: "Google Calendar authorization has been revoked. Please reconnect."

  def format_error(%{message: msg}), do: msg
  def format_error(other), do: inspect(other)
end
