defmodule MagusWeb.Rpc.ApiTokenController do
  @moduledoc """
  Personal access token management for the SvelteKit settings UI
  (`/rpc/api-tokens`). Runs in the `:rpc` pipeline (session-authenticated
  actor).

  Token creation is a controller rather than an AshTypescript RPC action
  because the one-time plaintext lives on the create result's `__metadata__`
  (never persisted) and is returned here exactly once; list/revoke can only
  ever see the stored 14-char display prefix. Responses mirror the
  AshTypescript RPC envelope (`{success, data | errors}`) so the SPA's data
  layer shares error handling.
  """
  use MagusWeb, :controller

  require Logger

  def index(conn, _params) do
    user = conn.assigns.current_user
    tokens = Magus.Accounts.list_api_tokens!(actor: user)
    json(conn, %{success: true, data: Enum.map(tokens, &serialize/1)})
  end

  def create(conn, params) do
    user = conn.assigns.current_user

    attrs = %{
      name: params["name"],
      scope: scope_from(params["scope"]),
      workspace_id: cast_uuid(params["workspaceId"]),
      expires_at: parse_datetime(params["expiresAt"]),
      created_via: :settings
    }

    case Magus.Accounts.create_api_token(attrs, actor: user) do
      {:ok, %{token: token, plaintext: plaintext}} ->
        json(conn, %{success: true, data: Map.put(serialize(token), :plaintext, plaintext)})

      {:error, reason} ->
        json(conn, error_envelope(reason))
    end
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, token} <- Magus.Accounts.get_api_token(id, actor: user),
         {:ok, _revoked} <- Magus.Accounts.revoke_api_token(token, actor: user) do
      json(conn, %{success: true, data: %{id: id}})
    else
      {:error, reason} -> json(conn, error_envelope(reason))
    end
  end

  defp serialize(token) do
    %{
      id: token.id,
      name: token.name,
      keyPrefix: token.key_prefix,
      scope: token.scope,
      createdVia: token.created_via,
      lastUsedAt: token.last_used_at,
      expiresAt: token.expires_at,
      revokedAt: token.revoked_at,
      workspaceId: token.workspace_id,
      insertedAt: token.inserted_at
    }
  end

  # Whitelist mirrors the classic settings form: never trust the raw value.
  defp scope_from("write"), do: :write
  defp scope_from(_), do: :read

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp parse_datetime(value) when is_binary(value) and value != "" do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp error_envelope(reason) do
    message =
      case reason do
        reason when is_binary(reason) ->
          reason

        %Ash.Error.Invalid{errors: [first | _]} when is_exception(first) ->
          Exception.message(first)

        other ->
          Logger.warning("API token request failed: #{inspect(other)}")
          "Request failed"
      end

    %{
      success: false,
      errors: [
        %{
          type: "api_token_error",
          message: message,
          shortMessage: "Request failed",
          vars: %{},
          fields: [],
          path: []
        }
      ]
    }
  end
end
