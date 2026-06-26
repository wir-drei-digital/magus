defmodule MagusWeb.Api.Plugs.RequireWorkspaceMatch do
  @moduledoc """
  Defense-in-depth workspace check for `/api/v2/*` controllers.

  Called from controllers AFTER the resource id has been resolved, this
  function compares `conn.assigns.current_token.workspace_id` against
  the resource's `workspace_id` and halts with 403 if they differ.

  The primary authorization happens at the Ash policy layer; this plug
  is a redundant boundary that fails closed on any cross-tenant query
  before it touches the domain.
  """

  import Plug.Conn

  @doc """
  Returns `{:ok, conn}` if the token and resource workspaces match,
  `{:error, halted_conn}` otherwise.
  """
  @spec check(Plug.Conn.t(), String.t() | nil) :: {:ok, Plug.Conn.t()} | {:error, Plug.Conn.t()}
  def check(conn, resource_workspace_id) do
    token = conn.assigns[:current_token]

    cond do
      is_nil(token) ->
        {:error, send_error(conn, 401, "missing_token", "Authentication required")}

      token.workspace_id == resource_workspace_id ->
        {:ok, conn}

      true ->
        {:error,
         send_error(
           conn,
           403,
           "workspace_mismatch",
           "This token is scoped to a different workspace than the requested resource"
         )}
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
