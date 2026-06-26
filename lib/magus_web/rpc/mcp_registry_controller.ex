defmodule MagusWeb.Rpc.McpRegistryController do
  @moduledoc """
  Browse + one-click import of MCP servers from the public registry for the
  SvelteKit settings UI (`/rpc/mcp/registry`). Runs in the `:rpc` pipeline
  (session-authenticated actor).

  A controller rather than an AshTypescript RPC action because the registry is an
  external catalog (not an Ash resource) and the import result carries a custom
  envelope (`status`, `requiredHeaders`, `alreadyImported`) that does not map to
  a plain resource read. Responses mirror the AshTypescript RPC envelope
  (`{success, data | errors}`) so the SPA's data layer shares error handling.
  """
  use MagusWeb, :controller

  require Logger

  alias Magus.MCP

  @max_limit 50

  def index(conn, params) do
    opts =
      [
        search: presence(params["q"]),
        cursor: presence(params["cursor"]),
        limit: clamp_limit(params["limit"])
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case MCP.list_registry_servers(opts) do
      {:ok, %{entries: entries, next_cursor: cursor}} ->
        json(conn, %{
          success: true,
          data: %{entries: Enum.map(entries, &serialize_entry/1), nextCursor: cursor}
        })

      {:error, reason} ->
        json(conn, error_envelope(reason))
    end
  end

  def import(conn, params) do
    user = conn.assigns.current_user
    registry_name = params["registryName"] || params["name"]

    opts =
      [
        version: presence(params["version"]),
        workspace_id: cast_uuid(params["workspaceId"])
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case registry_name do
      name when is_binary(name) and name != "" ->
        case MCP.import_from_registry(name, opts, user) do
          {:ok, result} -> json(conn, %{success: true, data: serialize_result(result)})
          {:error, reason} -> json(conn, error_envelope(reason))
        end

      _ ->
        json(conn, error_envelope("registryName is required"))
    end
  end

  @doc """
  Stores per-user static headers for a server and (re)runs discovery. The client
  sends already-resolved `headers` (`%{name => value}`), substituting the
  registry header templates with the secrets the user typed; these are the
  acting user's own credentials on an owner-only `ServerCredential` row.
  """
  def connect(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    headers = sanitize_headers(params["headers"])

    with {:ok, server} <- MCP.get_server(id, actor: user),
         {:ok, _cred} <-
           MCP.upsert_static_headers(%{mcp_server_id: id, static_headers: headers}, actor: user) do
      case MCP.discover_and_cache(server, user) do
        {:ok, discovered} ->
          json(conn, %{
            success: true,
            data: %{status: :connected, server: serialize_server(discovered)}
          })

        {:error, _reason} ->
          {:ok, reloaded} = MCP.get_server(id, actor: user)

          json(conn, %{success: true, data: %{status: :error, server: serialize_server(reloaded)}})
      end
    else
      {:error, reason} -> json(conn, error_envelope(reason))
    end
  end

  defp serialize_entry(entry) do
    %{
      registryName: entry.registry_name,
      displayName: entry.display_name,
      description: entry.description,
      version: entry.version,
      repositoryUrl: entry.repository_url,
      transport: entry.transport,
      authType: entry.auth_type,
      requiresAuth: entry.auth_type != :none,
      requiredHeaders: Enum.map(entry.required_headers, &serialize_header/1)
    }
  end

  defp serialize_header(h) do
    %{
      name: h.name,
      # The value template is public registry data (e.g. "Bearer {api_key}"); the
      # client substitutes its `vars` with the secrets the user types.
      template: h.template,
      vars: h.vars,
      secret: h.secret,
      required: h.required,
      description: h.description
    }
  end

  defp serialize_result(%{server: server} = result) do
    %{
      status: result.status,
      alreadyImported: result.already_imported,
      requiredHeaders: Enum.map(result.required_headers, &serialize_header/1),
      server: serialize_server(server)
    }
  end

  defp serialize_server(server) do
    %{
      id: server.id,
      name: server.name,
      handle: server.handle,
      authType: server.auth_type,
      reachability: server.reachability,
      workspaceId: server.workspace_id
    }
  end

  defp sanitize_headers(headers) when is_map(headers) do
    headers
    |> Enum.filter(fn {k, v} -> is_binary(k) and k != "" and is_binary(v) and v != "" end)
    |> Map.new()
  end

  defp sanitize_headers(_), do: %{}

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  defp clamp_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> min(n, @max_limit)
      _ -> nil
    end
  end

  defp clamp_limit(_), do: nil

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp error_envelope(reason) do
    message =
      case reason do
        msg when is_binary(msg) ->
          msg

        :registry_unavailable ->
          "The MCP registry is currently unavailable. Try again shortly."

        :not_found ->
          "That server was not found in the registry."

        :not_remote ->
          "That server has no remote (HTTP) endpoint and cannot be added."

        %Ash.Error.Invalid{errors: [first | _]} when is_exception(first) ->
          Exception.message(first)

        other ->
          Logger.warning("MCP registry request failed: #{inspect(other)}")
          "Request failed"
      end

    %{
      success: false,
      errors: [
        %{
          type: "mcp_registry_error",
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
