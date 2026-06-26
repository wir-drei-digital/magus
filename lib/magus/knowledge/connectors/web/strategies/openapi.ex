defmodule Magus.Knowledge.Connectors.Web.Strategies.OpenApi do
  @moduledoc """
  Discovery strategy for OpenAPI/Swagger specifications.

  Fetches an OpenAPI spec from `connection.seed_url`, extracts GET-only endpoints,
  and returns them either as live URLs (content mode) or as pre-rendered markdown
  documentation (spec_only mode).

  ## Modes

  - `spec_only` (default) — generates markdown documentation from the spec itself.
    Each returned item has `:spec_content` in its metadata.
  - `content` — returns live endpoint URLs for a subsequent fetch step.

  ## Config format

      %{
        "openapi" => %{
          "mode" => "spec_only",
          "include_tags" => ["Pages", "Blog"],
          "exclude_tags" => ["Media"],
          "include_paths" => ["/api/v1/pages"],
          "exclude_paths" => ["/api/v1/media"]
        }
      }

  ## Filtering precedence

  1. include_tags (nil = all tags pass)
  2. exclude_tags
  3. include_paths (empty = all paths pass)
  4. exclude_paths
  """

  @behaviour Magus.Knowledge.Connectors.Web.Strategies.Strategy

  @impl true
  def discover(connection, collection_settings, cursor) do
    with {:ok, body} <- fetch_spec(connection),
         {:ok, items, new_cursor} <-
           discover_from_spec(body, connection, collection_settings, cursor) do
      {:ok, items, new_cursor}
    end
  end

  @doc """
  Discovers endpoints from a pre-fetched spec body string.

  Used directly in tests to bypass HTTP.
  """
  def discover_from_spec(body, _connection, collection_settings, _cursor) do
    with {:ok, spec} <- parse_spec(body),
         {:ok, endpoints} <- extract_endpoints(spec, collection_settings) do
      mode = get_in(collection_settings, ["openapi", "mode"]) || "spec_only"
      items = Enum.map(endpoints, &build_item(&1, mode, spec))
      {:ok, items, nil}
    end
  end

  @doc """
  Parses a spec body as JSON (tried first) or YAML.

  Returns `{:ok, map}` or `{:error, reason}`.
  """
  def parse_spec(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, _} ->
        case YamlElixir.read_from_string(body) do
          {:ok, parsed} when is_map(parsed) -> {:ok, parsed}
          {:ok, _} -> {:error, :invalid_spec}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Extracts GET endpoints from a parsed OpenAPI spec map, applying tag and path filters.

  Returns `{:ok, [endpoint]}` where each endpoint is:

      %{
        url: "https://api.example.com/path",
        metadata: %{
          operation_id: "operationId",
          summary: "...",
          tags: [...],
          path: "/path"
        }
      }
  """
  def extract_endpoints(spec, collection_settings) do
    base_url = extract_base_url(spec)
    paths = Map.get(spec, "paths", %{})
    openapi_settings = Map.get(collection_settings, "openapi", %{}) || %{}

    include_tags = Map.get(openapi_settings, "include_tags")
    exclude_tags = Map.get(openapi_settings, "exclude_tags", []) || []
    include_paths = Map.get(openapi_settings, "include_paths", []) || []
    exclude_paths = Map.get(openapi_settings, "exclude_paths", []) || []

    endpoints =
      paths
      |> Enum.flat_map(fn {path, path_item} ->
        case Map.get(path_item, "get") do
          nil -> []
          operation -> [build_endpoint(base_url, path, operation)]
        end
      end)
      |> filter_by_include_tags(include_tags)
      |> filter_by_exclude_tags(exclude_tags)
      |> filter_by_include_paths(include_paths)
      |> filter_by_exclude_paths(exclude_paths)

    {:ok, endpoints}
  end

  @doc """
  Formats a single GET operation as a markdown documentation string.

  Used in `spec_only` mode to pre-render the spec content for each endpoint.
  """
  def format_endpoint_as_doc(path, _method, operation) do
    summary = Map.get(operation, "summary", "")
    description = Map.get(operation, "description", "")
    tags = Map.get(operation, "tags", [])
    parameters = Map.get(operation, "parameters", [])
    responses = Map.get(operation, "responses", %{})

    parts = ["# GET #{path}"]

    parts =
      if summary != "" do
        parts ++ ["\n#{summary}"]
      else
        parts
      end

    parts =
      if description != "" and description != summary do
        parts ++ ["\n#{description}"]
      else
        parts
      end

    parts =
      if tags != [] do
        parts ++ ["\n**Tags:** #{Enum.join(tags, ", ")}"]
      else
        parts
      end

    parts =
      if parameters != [] do
        param_lines =
          Enum.map(parameters, fn param ->
            name = Map.get(param, "name", "")
            location = Map.get(param, "in", "")
            param_desc = Map.get(param, "description", "")
            "- `#{name}` (#{location})#{if param_desc != "", do: " — #{param_desc}", else: ""}"
          end)

        parts ++ ["\n## Parameters\n\n#{Enum.join(param_lines, "\n")}"]
      else
        parts
      end

    parts =
      if map_size(responses) > 0 do
        response_lines =
          Enum.map(responses, fn {code, resp} ->
            resp_desc = Map.get(resp, "description", "")
            "- `#{code}`#{if resp_desc != "", do: " — #{resp_desc}", else: ""}"
          end)

        parts ++ ["\n## Responses\n\n#{Enum.join(response_lines, "\n")}"]
      else
        parts
      end

    Enum.join(parts, "\n")
  end

  # --- Private helpers ---

  defp fetch_spec(%{seed_url: url, auth_headers: auth_headers}) do
    headers = build_headers(auth_headers)

    case Req.get(url, headers: headers) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        body_string = if is_binary(body), do: body, else: Jason.encode!(body)
        {:ok, body_string}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_headers(auth_headers) when is_list(auth_headers), do: auth_headers
  defp build_headers(auth_headers) when is_map(auth_headers), do: Map.to_list(auth_headers)
  defp build_headers(_), do: []

  defp extract_base_url(spec) do
    case get_in(spec, ["servers", Access.at(0), "url"]) do
      nil -> ""
      url -> String.trim_trailing(url, "/")
    end
  end

  defp build_endpoint(base_url, path, operation) do
    %{
      url: "#{base_url}#{path}",
      metadata: %{
        operation_id: Map.get(operation, "operationId"),
        summary: Map.get(operation, "summary", ""),
        tags: Map.get(operation, "tags", []),
        path: path
      }
    }
  end

  defp filter_by_include_tags(endpoints, nil), do: endpoints
  defp filter_by_include_tags(endpoints, []), do: endpoints

  defp filter_by_include_tags(endpoints, include_tags) do
    Enum.filter(endpoints, fn ep ->
      Enum.any?(ep.metadata.tags, &(&1 in include_tags))
    end)
  end

  defp filter_by_exclude_tags(endpoints, []), do: endpoints

  defp filter_by_exclude_tags(endpoints, exclude_tags) do
    Enum.filter(endpoints, fn ep ->
      not Enum.any?(ep.metadata.tags, &(&1 in exclude_tags))
    end)
  end

  defp filter_by_include_paths(endpoints, []), do: endpoints

  defp filter_by_include_paths(endpoints, include_paths) do
    Enum.filter(endpoints, fn ep ->
      Enum.any?(include_paths, &String.starts_with?(ep.metadata.path, &1))
    end)
  end

  defp filter_by_exclude_paths(endpoints, []), do: endpoints

  defp filter_by_exclude_paths(endpoints, exclude_paths) do
    Enum.filter(endpoints, fn ep ->
      not Enum.any?(exclude_paths, &String.starts_with?(ep.metadata.path, &1))
    end)
  end

  defp build_item(endpoint, "spec_only", spec) do
    path = endpoint.metadata.path
    operation = get_in(spec, ["paths", path, "get"]) || %{}
    spec_content = format_endpoint_as_doc(path, "get", operation)
    put_in(endpoint, [:metadata, :spec_content], spec_content)
  end

  defp build_item(endpoint, _mode, _spec), do: endpoint
end
