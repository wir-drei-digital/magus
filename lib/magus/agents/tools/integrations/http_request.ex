defmodule Magus.Agents.Tools.Integrations.HttpRequest do
  @moduledoc """
  Agent tool that makes authenticated HTTP requests to user-configured API integrations.

  Loads credentials from the encrypted vault, builds auth headers based on the
  integration's configured auth method, and fires HTTP requests via Req.

  Includes SSRF protection via DNS-resolution-based URL validation.
  """

  use Jido.Action,
    name: "http_request",
    description:
      "Make an authenticated HTTP request to a configured API integration. " <>
        "Use this to interact with external APIs like Jira, GitHub, Notion, etc.",
    schema: [
      integration_id: [
        type: :string,
        required: true,
        doc: "The ID of the user integration to use"
      ],
      method: [
        type: {:in, ["GET", "POST", "PUT", "PATCH", "DELETE"]},
        required: true,
        doc: "HTTP method"
      ],
      path: [
        type: :string,
        required: true,
        doc: "URL path to append to the integration's base_url (e.g., /api/issues)"
      ],
      headers: [
        type: :map,
        default: %{},
        doc: "Additional HTTP headers to include"
      ],
      body: [
        type: {:or, [:map, :string, nil]},
        default: nil,
        doc: "Request body (used for POST/PUT/PATCH)"
      ]
    ]

  alias Magus.Agents.Signals
  alias Magus.Agents.Tools.Integrations.SsrfValidator

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2, get_param: 2, get_param: 3]

  @max_body_size 8_192

  def display_name, do: "Making API request..."

  def summarize_output(%{status: status}) when status >= 200 and status < 300 do
    "HTTP #{status} OK"
  end

  def summarize_output(%{status: status, error: error}) when is_binary(error) do
    "HTTP #{status} #{error}"
  end

  def summarize_output(%{error: error}) when is_binary(error) do
    "Error: #{error}"
  end

  def summarize_output(_), do: "Request completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:user_id]) do
      {:ok, ctx} ->
        execute_request(params, ctx, context)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp execute_request(params, ctx, context) do
    integration_id = get_param(params, :integration_id)
    method = get_param(params, :method)
    path = get_param(params, :path)
    custom_headers = get_param(params, :headers, %{})
    body = get_param(params, :body)

    with {:ok, integration} <- load_integration(integration_id),
         :ok <- verify_ownership(integration, ctx.user_id),
         {:ok, credentials} <- load_credentials(integration),
         {:ok, url} <- build_and_validate_url(integration, path),
         {:ok, auth_header} <- build_auth_header(integration.config, credentials) do
      headers = merge_headers(integration.config, custom_headers, auth_header)
      Signals.emit_tool_progress(context, :fetching, %{method: method, url: url})

      req_opts = build_req_opts(method, url, headers, body)
      execute_and_handle(req_opts)
    else
      {:error, message} -> {:ok, %{error: message}}
    end
  end

  defp load_integration(integration_id) do
    case Magus.Integrations.get_user_integration(integration_id,
           authorize?: false,
           load: [:credential]
         ) do
      {:ok, integration} ->
        {:ok, integration}

      {:error, _} ->
        {:error, "Integration not found"}
    end
  end

  defp verify_ownership(integration, user_id) do
    if integration.user_id == user_id do
      :ok
    else
      {:error, "You are not authorized to use this integration"}
    end
  end

  defp load_credentials(integration) do
    auth_method = get_in(integration.config, ["auth_method"]) || "none"

    if auth_method == "none" do
      {:ok, %{}}
    else
      case Magus.Integrations.load_credentials(integration.id) do
        {:ok, creds} ->
          {:ok, creds}

        {:error, :credentials_not_found} ->
          {:error,
           "No credentials found for this integration. Please configure credentials first."}

        {:error, _} ->
          {:error, "Failed to load credentials"}
      end
    end
  end

  defp build_and_validate_url(integration, path) do
    base_url = get_in(integration.config, ["base_url"]) || ""
    url = String.trim_trailing(base_url, "/") <> path

    if skip_ssrf_validation?() do
      {:ok, url}
    else
      case SsrfValidator.validate_url(url) do
        :ok -> {:ok, url}
        {:error, reason} -> {:error, "URL validation failed: #{reason}"}
      end
    end
  end

  defp skip_ssrf_validation? do
    Application.get_env(:magus, :http_request_req_options, [])
    |> Keyword.has_key?(:plug)
  end

  defp build_auth_header(config, credentials) do
    case config["auth_method"] do
      "bearer" ->
        token = credentials["token"]
        {:ok, {"authorization", "Bearer #{token}"}}

      "api_key_header" ->
        header_name = config["auth_header_name"] || "X-API-Key"
        api_key = credentials["api_key"]
        {:ok, {String.downcase(header_name), api_key}}

      "basic" ->
        username = credentials["username"] || ""
        password = credentials["password"] || ""
        encoded = Base.encode64("#{username}:#{password}")
        {:ok, {"authorization", "Basic #{encoded}"}}

      "none" ->
        {:ok, nil}

      _ ->
        {:ok, nil}
    end
  end

  defp merge_headers(config, custom_headers, auth_header) do
    default_headers = config["default_headers"] || %{}

    merged =
      default_headers
      |> Map.merge(custom_headers)
      |> Enum.map(fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)

    case auth_header do
      nil -> merged
      {key, value} -> [{key, value} | merged]
    end
  end

  defp build_req_opts(method, url, headers, body) do
    extra_opts = Application.get_env(:magus, :http_request_req_options, [])

    opts =
      [
        method: method_atom(method),
        url: url,
        headers: headers,
        connect_options: [timeout: 30_000],
        receive_timeout: 30_000,
        redirect: false
      ]
      |> Keyword.merge(extra_opts)

    if method in ["POST", "PUT", "PATCH"] && body != nil do
      Keyword.put(opts, :json, body)
    else
      opts
    end
  end

  defp method_atom("GET"), do: :get
  defp method_atom("POST"), do: :post
  defp method_atom("PUT"), do: :put
  defp method_atom("PATCH"), do: :patch
  defp method_atom("DELETE"), do: :delete

  defp execute_and_handle(req_opts) do
    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} ->
        {:ok, format_response(status, body)}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:ok, %{error: "Request timed out after 30 seconds"}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:ok, %{error: "Transport error: #{inspect(reason)}"}}

      {:error, reason} ->
        {:ok, %{error: "Request failed: #{inspect(reason)}"}}
    end
  end

  defp format_response(status, body) when status >= 200 and status < 300 do
    %{status: status, body: maybe_truncate(body)}
  end

  defp format_response(status, body) when status >= 400 and status < 500 do
    %{status: status, error: "client_error", body: maybe_truncate(body)}
  end

  defp format_response(status, body) when status >= 500 do
    %{status: status, error: "server_error", body: maybe_truncate(body)}
  end

  defp format_response(status, body) do
    %{status: status, body: maybe_truncate(body)}
  end

  defp maybe_truncate(body) when is_binary(body) and byte_size(body) > @max_body_size do
    String.slice(body, 0, @max_body_size) <> "... [truncated]"
  end

  defp maybe_truncate(body) when is_map(body) do
    encoded = Jason.encode!(body)

    if byte_size(encoded) > @max_body_size do
      String.slice(encoded, 0, @max_body_size) <> "... [truncated]"
    else
      body
    end
  end

  defp maybe_truncate(body), do: body
end
