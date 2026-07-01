defmodule Magus.Models.BaseUrlValidator do
  @moduledoc """
  Validates a user-supplied provider base URL to blunt SSRF: https only, no
  embedded credentials, and the resolved host must not fall in loopback,
  private, link-local, ULA, or cloud-metadata ranges. Admin providers are not
  routed through this (they may legitimately point at localhost).

  This is the thin POLICY layer. The resolved-host/IP blocklist is delegated to
  `Magus.Agents.Tools.Integrations.SsrfValidator`, the battle-tested validator
  already used by the HttpRequest tool. That module covers IPv4/IPv6 loopback,
  private, link-local (fe80::/10), ULA, metadata, 0.0.0.0, and IPv4-mapped IPv6
  (::ffff:x). We layer a stricter policy on top: https-only (SsrfValidator also
  allows http) and rejection of embedded credentials.

  Limitation: DNS rebinding / TOCTOU is not fully closed by a static check
  plus validation-time resolution. A per-request egress guard is a later item.
  """

  alias Magus.Agents.Tools.Integrations.SsrfValidator

  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(url) when is_binary(url) and url != "" do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" ->
        delegate_host_check(url)

      %URI{userinfo: info} when not is_nil(info) ->
        {:error, "must not embed credentials"}

      %URI{scheme: "https"} ->
        {:error, "must include a host"}

      _ ->
        {:error, "must be an https URL"}
    end
  end

  def validate(_), do: {:error, "must be an https URL"}

  defp delegate_host_check(url) do
    case SsrfValidator.validate_url(url) do
      :ok -> :ok
      {:error, _} -> {:error, "must not target a private host"}
    end
  end
end
