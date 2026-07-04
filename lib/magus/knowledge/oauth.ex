defmodule Magus.Knowledge.OAuth do
  @moduledoc """
  Google OAuth credential lookup and token refresh for knowledge sources.

  This is the single place that reads `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`
  and talks to Google's token endpoint. It classifies an `invalid_grant`
  response (revoked or expired refresh token) as `{:error, :reauth_required}` so
  callers can stop retrying and prompt the user to reconnect, distinct from
  transient network or 5xx failures which are safe to retry.
  """

  require Logger

  @default_token_url "https://oauth2.googleapis.com/token"

  @doc """
  Returns `{:ok, {client_id, client_secret}}` or `{:error, :missing_oauth_config}`.
  """
  def google_credentials do
    client_id = System.get_env("GOOGLE_CLIENT_ID")
    client_secret = System.get_env("GOOGLE_CLIENT_SECRET")

    if is_binary(client_id) and client_id != "" and is_binary(client_secret) and
         client_secret != "" do
      {:ok, {client_id, client_secret}}
    else
      {:error, :missing_oauth_config}
    end
  end

  @doc """
  Exchanges a refresh token for a fresh access token.

  On success returns a map with `"access_token"`, `"refresh_token"` (the newly
  issued one, or the caller's if Google did not rotate it), and `"expires_at"`
  (ISO8601). See the moduledoc for the error taxonomy.
  """
  def refresh_google_token(refresh_token) when is_binary(refresh_token) do
    with {:ok, {client_id, client_secret}} <- google_credentials() do
      body = [
        grant_type: "refresh_token",
        refresh_token: refresh_token,
        client_id: client_id,
        client_secret: client_secret
      ]

      case Req.post(token_url(), form: body, receive_timeout: 10_000, max_retries: 0) do
        {:ok, %Req.Response{status: 200, body: %{"access_token" => access} = tokens}} ->
          Logger.info("Knowledge OAuth: refreshed Google access token")

          {:ok,
           %{
             "access_token" => access,
             "refresh_token" => tokens["refresh_token"] || refresh_token,
             "expires_at" => calculate_expiry(tokens["expires_in"])
           }}

        {:ok, %Req.Response{status: 400, body: %{"error" => "invalid_grant"}}} ->
          Logger.warning("Knowledge OAuth: refresh token revoked/expired (invalid_grant)")
          {:error, :reauth_required}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:refresh_failed, status, body}}

        {:error, reason} ->
          {:error, {:network_error, reason}}
      end
    end
  end

  defp token_url do
    Application.get_env(:magus, :google_token_url, @default_token_url)
  end

  defp calculate_expiry(expires_in) when is_integer(expires_in) do
    DateTime.utc_now() |> DateTime.add(expires_in, :second) |> DateTime.to_iso8601()
  end

  defp calculate_expiry(_), do: nil
end
