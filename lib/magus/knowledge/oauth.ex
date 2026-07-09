defmodule Magus.Knowledge.OAuth do
  @moduledoc """
  Per-provider OAuth credential lookup and token refresh for knowledge sources.

  This is the single place that reads a provider's client id/secret env vars and
  talks to its token endpoint. It classifies an `invalid_grant` response (revoked
  or expired refresh token) as `{:error, :reauth_required}` so callers can stop
  retrying and prompt the user to reconnect, distinct from transient network or
  5xx failures which are safe to retry.

  Supported providers: `:google_drive`, `:onedrive`, `:dropbox`. All three use a
  `grant_type=refresh_token` form POST with client id/secret in the body and
  return standard OAuth JSON. Microsoft (`:onedrive`) rotates the refresh token
  on every refresh; the returned `"refresh_token"` is the rotated one when the
  provider issued one, else the caller's.
  """

  require Logger

  @provider_config %{
    google_drive: %{
      token_url_key: :google_token_url,
      default_token_url: "https://oauth2.googleapis.com/token",
      client_id_env: "GOOGLE_CLIENT_ID",
      client_secret_env: "GOOGLE_CLIENT_SECRET"
    },
    onedrive: %{
      token_url_key: :onedrive_token_url,
      default_token_url: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
      client_id_env: "ONEDRIVE_CLIENT_ID",
      client_secret_env: "ONEDRIVE_CLIENT_SECRET"
    },
    dropbox: %{
      token_url_key: :dropbox_token_url,
      default_token_url: "https://api.dropboxapi.com/oauth2/token",
      client_id_env: "DROPBOX_APP_KEY",
      client_secret_env: "DROPBOX_APP_SECRET"
    }
  }

  @doc """
  Returns `{:ok, {client_id, client_secret}}` for the given provider, or
  `{:error, :missing_oauth_config}` when either env var is unset/blank.
  """
  def credentials(provider) do
    config = Map.fetch!(@provider_config, provider)
    client_id = System.get_env(config.client_id_env)
    client_secret = System.get_env(config.client_secret_env)

    if is_binary(client_id) and client_id != "" and is_binary(client_secret) and
         client_secret != "" do
      {:ok, {client_id, client_secret}}
    else
      {:error, :missing_oauth_config}
    end
  end

  @doc """
  Exchanges a refresh token for a fresh access token for the given provider.

  On success returns a map with `"access_token"`, `"refresh_token"` (the newly
  issued one, or the caller's if the provider did not rotate it), and
  `"expires_at"` (ISO8601). See the moduledoc for the error taxonomy.
  """
  def refresh_token(provider, refresh_token) when is_binary(refresh_token) do
    with {:ok, {client_id, client_secret}} <- credentials(provider) do
      body = [
        grant_type: "refresh_token",
        refresh_token: refresh_token,
        client_id: client_id,
        client_secret: client_secret
      ]

      case Req.post(token_url(provider), form: body, receive_timeout: 10_000, max_retries: 0) do
        {:ok, %Req.Response{status: 200, body: %{"access_token" => access} = tokens}} ->
          Logger.info("Knowledge OAuth: refreshed #{provider} access token")

          {:ok,
           %{
             "access_token" => access,
             "refresh_token" => tokens["refresh_token"] || refresh_token,
             "expires_at" => calculate_expiry(tokens["expires_in"])
           }}

        {:ok, %Req.Response{status: 400, body: %{"error" => "invalid_grant"}}} ->
          Logger.warning(
            "Knowledge OAuth: #{provider} refresh token revoked/expired (invalid_grant)"
          )

          {:error, :reauth_required}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:refresh_failed, status, body}}

        {:error, reason} ->
          {:error, {:network_error, reason}}
      end
    end
  end

  @doc """
  Back-compat delegator for the Drive connector's reactive refresh path.
  """
  def refresh_google_token(refresh_token), do: refresh_token(:google_drive, refresh_token)

  @doc """
  Back-compat delegator returning Google client credentials.
  """
  def google_credentials, do: credentials(:google_drive)

  defp token_url(provider) do
    config = Map.fetch!(@provider_config, provider)
    Application.get_env(:magus, config.token_url_key, config.default_token_url)
  end

  defp calculate_expiry(expires_in) when is_integer(expires_in) do
    DateTime.utc_now() |> DateTime.add(expires_in, :second) |> DateTime.to_iso8601()
  end

  defp calculate_expiry(_), do: nil
end
