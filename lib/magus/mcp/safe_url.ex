defmodule Magus.MCP.SafeUrl do
  @moduledoc """
  SSRF validation for user-supplied MCP server URLs.

  Wraps `Magus.Agents.Tools.Integrations.SsrfValidator` and adds a config-gated
  bypass so dev and test can target local servers (Bypass binds to 127.0.0.1).
  Production never sets `allow_private_urls`, so private/reserved IPs are rejected.
  """

  alias Magus.Agents.Tools.Integrations.SsrfValidator

  @spec validate(String.t()) :: :ok | {:error, String.t()}
  def validate(url) when is_binary(url) do
    if allow_private_urls?() do
      case URI.parse(url) do
        %URI{scheme: s, host: h} when s in ["http", "https"] and is_binary(h) and h != "" -> :ok
        _ -> {:error, "Invalid URL"}
      end
    else
      SsrfValidator.validate_url(url)
    end
  end

  def validate(_), do: {:error, "Invalid URL"}

  defp allow_private_urls? do
    Application.get_env(:magus, Magus.MCP, [])[:allow_private_urls] == true
  end
end
