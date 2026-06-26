defmodule Magus.Agents.Tools.Web.UrlHelpers do
  @moduledoc """
  Provider-agnostic URL validation shared by the web tools.

  HTTP transport now lives in each capability adapter
  (`Magus.Capabilities.Search.Exa`, `Magus.Capabilities.Crawl.Spider`), so this
  module keeps only the generic URL check.
  """

  @doc "Validate that a URL has a valid http/https scheme and host."
  def valid_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  def valid_url?(_), do: false
end
