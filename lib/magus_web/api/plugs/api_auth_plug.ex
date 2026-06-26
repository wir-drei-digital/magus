defmodule MagusWeb.Api.Plugs.ApiAuthPlug do
  @moduledoc """
  Authenticates API requests via Bearer token.
  Looks up the API key by SHA-256 hash, loads the UserIntegration and User.
  Assigns :api_integration and :current_user to the conn.
  """

  import Plug.Conn

  alias Magus.Integrations
  alias Magus.Integrations.Providers.Api, as: ApiProvider

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, token} <- extract_bearer_token(conn),
         {:ok, credential} <- find_credential(token),
         {:ok, integration} <- load_integration(credential),
         :ok <- validate_integration(integration) do
      conn
      |> assign(:api_integration, integration)
      |> assign(:current_user, integration.user)
    else
      {:error, :no_token} ->
        send_error(conn, 401, "invalid_api_key", "Missing or invalid Authorization header")

      {:error, :invalid_format} ->
        send_error(conn, 401, "invalid_api_key", "Authorization header must use Bearer scheme")

      {:error, :not_found} ->
        send_error(conn, 401, "invalid_api_key", "Invalid API key")

      {:error, :inactive} ->
        send_error(conn, 403, "integration_inactive", "This API integration is not active")

      {:error, :wrong_provider} ->
        send_error(conn, 403, "integration_inactive", "This credential is not an API integration")
    end
  end

  defp extract_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      [_other] -> {:error, :invalid_format}
      [] -> {:error, :no_token}
    end
  end

  defp find_credential(token) do
    key_hash = ApiProvider.hash_api_key(token)

    case Integrations.get_credential_by_key_hash(key_hash, authorize?: false) do
      {:ok, credential} -> {:ok, credential}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp load_integration(credential) do
    case Integrations.get_user_integration(credential.user_integration_id,
           authorize?: false,
           load: [:user]
         ) do
      {:ok, integration} -> {:ok, integration}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp validate_integration(integration) do
    cond do
      integration.provider_key != :api -> {:error, :wrong_provider}
      integration.status != :active -> {:error, :inactive}
      true -> :ok
    end
  end

  defp send_error(conn, status, code, message) do
    body = Jason.encode!(%{"error" => %{"code" => code, "message" => message}})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end
