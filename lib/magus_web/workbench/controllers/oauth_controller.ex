defmodule MagusWeb.OAuthController do
  @moduledoc """
  Handles OAuth flows for integration providers (Google Calendar, etc.).

  Flow:
  1. User clicks "Connect" → `authorize/2` redirects to provider's OAuth consent screen
  2. User grants permission → provider redirects to `callback/2`
  3. `callback/2` exchanges code for tokens and stores them encrypted
  """

  use MagusWeb, :controller

  require Logger

  alias Magus.Integrations

  @doc """
  Start OAuth flow by redirecting to provider's authorization URL.

  GET /oauth/:provider/authorize
  """
  def authorize(conn, %{"provider" => provider_key_str}) do
    user = conn.assigns.current_user

    with provider_key when not is_nil(provider_key) <- parse_provider_key(provider_key_str),
         provider when not is_nil(provider) <- get_provider_module(provider_key),
         true <- function_exported?(provider, :oauth_config, 0) do
      config = provider.oauth_config()
      state = generate_oauth_state(user.id, provider_key)

      params =
        %{
          client_id: config.client_id,
          redirect_uri: oauth_callback_url(conn, provider_key),
          response_type: "code",
          scope: Enum.join(config.scopes, " "),
          state: state,
          access_type: "offline",
          prompt: "consent"
        }
        |> Map.merge(Map.get(config, :extra_authorize_params, %{}))

      authorize_url = "#{config.authorize_url}?#{URI.encode_query(params)}"

      return_to = conn.params["return_to"]

      conn =
        if return_to, do: Plug.Conn.put_session(conn, :oauth_return_to, return_to), else: conn

      redirect(conn, external: authorize_url)
    else
      false ->
        conn
        |> put_flash(:error, gettext("This provider doesn't support OAuth"))
        |> redirect_to_return_path()

      _ ->
        conn
        |> put_flash(:error, gettext("Unknown provider"))
        |> redirect_to_return_path()
    end
  end

  @doc """
  Handle OAuth callback from provider.

  GET /oauth/:provider/callback
  """
  def callback(conn, %{"provider" => provider_key_str, "code" => code, "state" => state}) do
    user = conn.assigns.current_user
    provider_key = parse_provider_key(provider_key_str)

    if is_nil(provider_key) do
      conn
      |> put_flash(:error, gettext("Unknown provider"))
      |> redirect_to_return_path()
    else
      handle_oauth_callback(conn, user, provider_key, code, state)
    end
  end

  def callback(conn, %{"provider" => provider_key, "error" => error}) do
    Logger.warning("OAuth callback error for #{provider_key}: #{error}")

    error_message =
      case error do
        "access_denied" -> gettext("Access was denied. Please try again.")
        _ -> gettext("OAuth error: %{error}", error: error)
      end

    conn
    |> put_flash(:error, error_message)
    |> redirect_to_return_path()
  end

  defp handle_oauth_callback(conn, user, provider_key, code, state) do
    with {:ok, state_user_id} <- verify_oauth_state(state, provider_key),
         :ok <- verify_state_matches_session(state_user_id, user.id),
         provider when not is_nil(provider) <- get_provider_module(provider_key),
         config <- provider.oauth_config(),
         {:ok, tokens} <- exchange_code(config, code, oauth_callback_url(conn, provider_key)) do
      # For knowledge providers, store tokens in session so the wizard can pick them up.
      # For agent integrations, store in the database as before.
      if provider.source_type() == :knowledge do
        conn
        |> Plug.Conn.put_session(:knowledge_oauth_tokens, tokens)
        |> put_flash(
          :info,
          gettext("Successfully connected %{provider}!", provider: provider.name())
        )
        |> redirect_to_return_path()
      else
        case store_credentials(user, provider_key, tokens) do
          {:ok, _} ->
            conn
            |> put_flash(
              :info,
              gettext("Successfully connected %{provider}!", provider: provider.name())
            )
            |> redirect_to_return_path()

          {:error, reason} ->
            {:error, reason}
        end
      end
    else
      {:error, :invalid_state} ->
        Logger.warning("OAuth callback with invalid state for #{provider_key}")

        conn
        |> put_flash(:error, gettext("Invalid OAuth state. Please try again."))
        |> redirect_to_return_path()

      {:error, reason} ->
        Logger.error("OAuth callback failed for #{provider_key}: #{inspect(reason)}")

        conn
        |> put_flash(
          :error,
          gettext("Failed to connect: %{reason}", reason: format_error(reason))
        )
        |> redirect_to_return_path()

      nil ->
        conn
        |> put_flash(:error, gettext("Unknown provider"))
        |> redirect_to_return_path()
    end
  end

  defp redirect_to_return_path(conn) do
    return_to = Plug.Conn.get_session(conn, :oauth_return_to) || ~p"/settings/integrations"

    conn
    |> Plug.Conn.delete_session(:oauth_return_to)
    |> redirect(to: return_to)
  end

  # Exchange authorization code for access/refresh tokens.
  # Supports two token auth methods:
  #   - :basic — HTTP Basic auth (e.g. Notion)
  #   - default — client_id/secret in POST body (e.g. Google)
  defp exchange_code(config, code, redirect_uri) do
    body = %{
      grant_type: "authorization_code",
      code: code,
      redirect_uri: redirect_uri
    }

    # Notion requires Basic auth; most providers send credentials in the POST body
    {body, req_opts} =
      if Map.get(config, :token_auth_method) == :basic do
        encoded = Base.encode64("#{config.client_id}:#{config.client_secret}")
        {body, [headers: [{"authorization", "Basic #{encoded}"}]]}
      else
        {Map.merge(body, %{client_id: config.client_id, client_secret: config.client_secret}), []}
      end

    case Req.post(config.token_url, [form: Map.to_list(body)] ++ req_opts) do
      {:ok, %{status: 200, body: tokens}} ->
        {:ok,
         %{
           "access_token" => tokens["access_token"],
           "refresh_token" => tokens["refresh_token"],
           "expires_at" => calculate_expiry(tokens["expires_in"])
         }}

      {:ok, %{status: status, body: body}} ->
        Logger.error("OAuth token exchange failed: status=#{status}, body=#{inspect(body)}")
        {:error, body["error_description"] || body["error"] || "Token exchange failed"}

      {:error, reason} ->
        Logger.error("OAuth token exchange request failed: #{inspect(reason)}")
        {:error, "Network error during token exchange"}
    end
  end

  defp calculate_expiry(expires_in) when is_integer(expires_in) do
    DateTime.utc_now()
    |> DateTime.add(expires_in, :second)
    |> DateTime.to_iso8601()
  end

  defp calculate_expiry(_), do: nil

  # Verify the user_id from the OAuth state matches the current session user.
  # Prevents a stolen state token from being used by a different user.
  defp verify_state_matches_session(state_user_id, session_user_id) do
    if state_user_id == session_user_id do
      :ok
    else
      Logger.warning(
        "OAuth state user_id mismatch: state=#{state_user_id}, session=#{session_user_id}"
      )

      {:error, :invalid_state}
    end
  end

  # Store credentials in the database.
  # OAuth flow currently only supports updating existing integrations that were
  # created through the agent form (which sets custom_agent_id). Creating new
  # integrations requires agent context that the OAuth flow doesn't carry yet.
  defp store_credentials(user, provider_key, tokens) do
    case Integrations.list_user_integrations_by_provider(user.id, provider_key, actor: user) do
      {:ok, [existing | _]} ->
        update_existing_credentials(existing, tokens)

      {:ok, []} ->
        {:error,
         "No integration found. Please set up the integration in your agent's settings first, then reconnect."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_existing_credentials(integration, tokens) do
    result =
      case Integrations.get_credential_for_integration(integration.id, authorize?: false) do
        {:ok, credential} ->
          Integrations.refresh_credential(
            credential,
            %{
              encrypted_data: tokens,
              expires_at: parse_expiry(tokens["expires_at"])
            },
            authorize?: false
          )

        {:error, _} ->
          Integrations.create_credential(
            %{
              user_integration_id: integration.id,
              credential_type: :oauth2,
              encrypted_data: tokens,
              expires_at: parse_expiry(tokens["expires_at"])
            },
            authorize?: false
          )
      end

    with {:ok, credential} <- result do
      case Integrations.reactivate_if_errored(integration, authorize?: false) do
        {:ok, _integration} ->
          {:ok, credential}

        {:error, reason} ->
          Logger.error(
            "Failed to reactivate integration #{integration.id} after credential refresh: #{inspect(reason)}"
          )

          {:ok, credential}
      end
    end
  end

  defp parse_expiry(nil), do: nil

  defp parse_expiry(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_expiry(_), do: nil

  # Generate HMAC-signed state parameter
  defp generate_oauth_state(user_id, provider_key) do
    data = "#{user_id}:#{provider_key}:#{System.system_time(:second)}"
    signature = :crypto.mac(:hmac, :sha256, oauth_secret(), data) |> Base.url_encode64()
    Base.url_encode64("#{data}:#{signature}")
  end

  # Verify HMAC-signed state parameter
  defp verify_oauth_state(state, expected_provider) do
    with {:ok, decoded} <- Base.url_decode64(state),
         [user_id, provider, timestamp, signature] <- String.split(decoded, ":"),
         true <- provider == to_string(expected_provider),
         true <- verify_signature("#{user_id}:#{provider}:#{timestamp}", signature),
         true <- verify_timestamp(timestamp) do
      {:ok, user_id}
    else
      _ -> {:error, :invalid_state}
    end
  end

  defp verify_signature(data, signature) do
    expected = :crypto.mac(:hmac, :sha256, oauth_secret(), data) |> Base.url_encode64()
    Plug.Crypto.secure_compare(expected, signature)
  end

  defp verify_timestamp(timestamp) do
    case Integer.parse(timestamp) do
      {ts, ""} ->
        # State is valid for 10 minutes
        System.system_time(:second) - ts < 600

      _ ->
        false
    end
  end

  defp oauth_secret do
    Application.get_env(:magus, :oauth_state_secret) ||
      Application.get_env(:magus, MagusWeb.Endpoint)[:secret_key_base]
  end

  defp oauth_callback_url(conn, provider_key) do
    url(conn, ~p"/oauth/#{provider_key}/callback")
  end

  defp get_provider_module(provider_key) do
    Integrations.get_provider_module(provider_key)
  end

  defp parse_provider_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp parse_provider_key(key) when is_atom(key), do: key

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(_), do: "Unknown error"
end
