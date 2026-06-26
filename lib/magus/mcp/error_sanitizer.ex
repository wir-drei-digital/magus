defmodule Magus.MCP.ErrorSanitizer do
  @moduledoc """
  Maps raw connection/transport errors to a small set of safe, human-readable
  categories before they are stored in `Server.last_error`.

  `last_error` is readable by any workspace member at the `:viewer` role, so the
  raw `inspect(reason)` of a transport error (which can embed request headers or
  token fragments) must never land there. Operators still get the full detail via
  `Logger.warning`; the column only gets the category.
  """

  @doc """
  Reduces an arbitrary error reason to a safe category string.
  """
  @spec categorize(term()) :: String.t()
  def categorize(:econnrefused), do: "Connection refused"
  def categorize(:timeout), do: "Connection timed out"
  def categorize(:initialization_timeout), do: "Server initialization timeout"
  def categorize(:process_not_found), do: "Server process unavailable"
  def categorize(:nxdomain), do: "Hostname could not be resolved"
  def categorize(:closed), do: "Connection closed by server"

  def categorize({:ssrf_blocked, _}), do: "Address blocked by security policy"
  def categorize({:unexpected_tools_response, _}), do: "Invalid server response"
  def categorize({:invalid_tool_definition, _}), do: "Invalid server response"

  # TLS / certificate verification failures from :ssl / :tls_alert.
  def categorize({:tls_alert, _}), do: "TLS verification failed"
  def categorize({:options, {:certificate, _}}), do: "TLS verification failed"

  # Unwrap common nested transport tuples and recurse on the inner reason.
  def categorize({:transport_error, reason}), do: categorize(reason)
  def categorize({:error, reason}), do: categorize(reason)

  def categorize(_), do: "Connection failed"
end
