defmodule MagusWeb.Api.Plugs.ApiTokenAuthPlug do
  @moduledoc """
  Authenticates Brain API requests via Bearer Personal Access Tokens.

  On success, assigns `:current_user` and `:current_token` on the conn
  and asynchronously updates the token's `last_used_at`. Token extraction
  and user resolution are split so future OAuth bearer tokens can plug
  into the same downstream pipeline by adding a new extractor.
  """

  import Plug.Conn
  require Logger

  alias Magus.Accounts
  alias Magus.Accounts.ApiToken.Secret

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, plaintext} <- extract_bearer(conn),
         {:ok, token} <- lookup_token(plaintext) do
      Task.Supervisor.start_child(Magus.AgentLoopTaskSupervisor, fn ->
        case Accounts.touch_api_token(token, authorize?: false) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to touch api_token #{token.id}: #{inspect(reason)}")
        end
      end)

      conn
      |> assign(:current_user, token.user)
      |> assign(:current_token, token)
    else
      {:error, code} -> send_error(conn, 401, code, error_message(code))
    end
  end

  defp extract_bearer(conn) do
    case get_req_header(conn, "authorization") do
      [header] ->
        case String.split(header, " ", parts: 2) do
          [scheme, token] ->
            if String.downcase(scheme) == "bearer" do
              case String.trim(token) do
                "" -> {:error, :missing_token}
                trimmed -> {:ok, trimmed}
              end
            else
              {:error, :invalid_scheme}
            end

          _ ->
            {:error, :invalid_scheme}
        end

      [] ->
        {:error, :missing_token}

      _ ->
        {:error, :missing_token}
    end
  end

  defp lookup_token(plaintext) do
    hash = Secret.hash(plaintext)

    case Accounts.get_api_token_by_hash(hash, authorize?: false) do
      {:ok, token} -> {:ok, token}
      {:error, _} -> {:error, :invalid_token}
    end
  end

  defp error_message(:missing_token), do: "Missing Authorization: Bearer header"
  defp error_message(:invalid_scheme), do: "Authorization header must use Bearer scheme"
  defp error_message(:invalid_token), do: "Invalid, revoked, or expired token"

  defp send_error(conn, status, code, message) do
    body = Jason.encode!(%{"error" => %{"code" => to_string(code), "message" => message}})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end
