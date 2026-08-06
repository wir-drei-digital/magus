defmodule Magus.Knowledge.TransportPolicy do
  @moduledoc """
  Deployment policy for user-supplied knowledge-source endpoints (generic
  WebDAV and Nextcloud base URLs).

  Default is strict: `https://` only, and the host must not resolve to a
  private/reserved range (SSRF: a user-supplied endpoint is fetched
  server-side with the user's credentials, and the response body lands in the
  knowledge base). Self-hosted deployments syncing a LAN NAS over plain http
  opt out with

      config :magus, :knowledge_transport, allow_insecure: true

  or `MAGUS_ALLOW_INSECURE_KNOWLEDGE_TRANSPORT=true` on a release.

  Range checking delegates to `Magus.Agents.Tools.Integrations.SsrfValidator`
  (the same DNS-resolution-based validator the BYOK provider endpoints use).
  """

  alias Magus.Agents.Tools.Integrations.SsrfValidator

  @spec validate_base_url(String.t()) :: :ok | {:error, :https_required | :blocked_host}
  def validate_base_url(url) when is_binary(url) do
    if allow_insecure?() do
      :ok
    else
      with :ok <- require_https(url) do
        case SsrfValidator.validate_url(url) do
          :ok -> :ok
          {:error, _reason} -> {:error, :blocked_host}
        end
      end
    end
  end

  defp require_https(url) do
    case URI.parse(url) do
      %URI{scheme: "https"} -> :ok
      _ -> {:error, :https_required}
    end
  end

  defp allow_insecure? do
    :magus
    |> Application.get_env(:knowledge_transport, [])
    |> Keyword.get(:allow_insecure, false)
  end
end
