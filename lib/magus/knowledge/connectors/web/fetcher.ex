defmodule Magus.Knowledge.Connectors.Web.Fetcher do
  @moduledoc """
  Fetches web content and returns it as markdown with a content hash.

  Routes requests based on content type:
  - HTML → Spider cloud /scrape endpoint (returns markdown)
  - JSON → Direct Req.get, formatted as markdown code block
  - XML / other → Direct Req.get, raw content

  Applies rate limiting (default 500ms delay) before each fetch.
  Content is hashed with SHA-256 and truncated at 500KB if needed.
  """

  require Logger

  @spider_base_url "https://api.spider.cloud/v1"
  @max_content_bytes 500_000
  @default_rate_delay 500

  @doc """
  Fetches the content at `url` and returns `{:ok, content, metadata}` or `{:error, reason}`.

  ## Options

    * `:auth_headers` - Additional headers to include (keyword list or list of tuples)
    * `:rate_delay` - Milliseconds to sleep before fetching (default: #{@default_rate_delay})
    * `:boundary_config` - Boundary config map (unused at this layer, passed through for callers)
    * `:robots_rules` - Robots rules list (unused at this layer, passed through for callers)

  ## Returns

    * `{:ok, content, %{"content_hash" => hash, "fetched_at" => iso8601}}` on success
    * `{:error, reason}` on failure

  """
  @spec fetch(String.t(), keyword()) ::
          {:ok, String.t(), map()} | {:error, atom() | {atom(), any()}}
  def fetch(url, opts \\ []) do
    rate_delay = Keyword.get(opts, :rate_delay, @default_rate_delay)
    auth_headers = Keyword.get(opts, :auth_headers, [])

    if rate_delay > 0, do: Process.sleep(rate_delay)

    with {:ok, content_type} <- detect_via_head(url, auth_headers),
         {:ok, content} <- fetch_by_type(url, content_type, auth_headers) do
      truncated = truncate_content(content)
      hash = content_hash(truncated)

      metadata = %{
        "content_hash" => hash,
        "fetched_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      {:ok, truncated, metadata}
    end
  end

  @doc """
  Returns a SHA-256 hash of `content` with a "sha256:" prefix.
  """
  @spec content_hash(String.t()) :: String.t()
  def content_hash(content) when is_binary(content) do
    hex = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    "sha256:#{hex}"
  end

  @doc """
  Truncates `content` to `limit` bytes. If truncated, appends `\\n\\n[Content truncated]`.

  Default limit is 500,000 bytes.
  """
  @spec truncate_content(String.t(), non_neg_integer()) :: String.t()
  def truncate_content(content, limit \\ @max_content_bytes) when is_binary(content) do
    if byte_size(content) <= limit do
      content
    else
      truncated = binary_part(content, 0, limit)

      safe =
        case :unicode.characters_to_binary(truncated) do
          {:incomplete, valid, _} -> valid
          {:error, valid, _} -> valid
          valid when is_binary(valid) -> valid
        end

      safe <> "\n\n[Content truncated]"
    end
  end

  @doc """
  Detects the content type from response headers.

  Accepts both the new Req 0.5+ map format `%{String.t() => [String.t()]}` and the
  old tuple-list format `[{String.t(), String.t()}]`.

  Returns `:html`, `:json`, `:xml`, or `:other`.
  """
  @spec detect_content_type(map() | list()) :: :html | :json | :xml | :other
  def detect_content_type(headers) when is_map(headers) do
    value =
      headers
      |> Map.get("content-type", [""])
      |> List.first("")

    classify_content_type(value)
  end

  def detect_content_type(headers) when is_list(headers) do
    value =
      Enum.find_value(headers, "", fn
        {key, val} when is_binary(key) and is_binary(val) ->
          if String.downcase(key) == "content-type", do: val, else: nil

        _ ->
          nil
      end)

    classify_content_type(value)
  end

  @doc """
  Formats `data` (any JSON-encodable term) as a markdown JSON code block.
  """
  @spec format_json_as_markdown(any()) :: String.t()
  def format_json_as_markdown(data) do
    json = Jason.encode!(data, pretty: true)
    "```json\n#{json}\n```"
  end

  # --- Private helpers ---

  defp detect_via_head(url, auth_headers) do
    req = build_req(url, auth_headers)

    case Req.head(req, url: url) do
      {:ok, %{headers: headers}} ->
        {:ok, detect_content_type(headers)}

      {:error, reason} ->
        Logger.warning("HEAD request failed for #{url}: #{inspect(reason)}, defaulting to :other")
        {:ok, :other}
    end
  end

  defp fetch_by_type(url, :html, _auth_headers) do
    fetch_via_spider(url)
  end

  defp fetch_by_type(url, :json, auth_headers) do
    req = build_req(url, auth_headers)

    case Req.get(req, url: url) do
      {:ok, %{status: 200, body: body}} ->
        content =
          if is_map(body) or is_list(body) do
            format_json_as_markdown(body)
          else
            case Jason.decode(body) do
              {:ok, decoded} -> format_json_as_markdown(decoded)
              {:error, _} -> to_string(body)
            end
          end

        {:ok, content}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp fetch_by_type(url, _type, auth_headers) do
    req = build_req(url, auth_headers)

    case Req.get(req, url: url) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, to_string(body)}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp fetch_via_spider(url) do
    case System.get_env("SPIDER_API_KEY") do
      nil ->
        {:error, :spider_api_key_required}

      api_key ->
        body = %{"url" => url, "return_format" => "markdown", "limit" => 1}

        headers = [
          {"Authorization", "Bearer #{api_key}"},
          {"Content-Type", "application/json"}
        ]

        extra_opts = Application.get_env(:magus, :spider_req_options, [])

        req =
          Req.new(
            Keyword.merge(
              [
                url: "#{@spider_base_url}/scrape",
                method: :post,
                json: body,
                headers: headers,
                receive_timeout: 120_000
              ],
              extra_opts
            )
          )

        case Req.request(req) do
          {:ok, %{status: 200, body: response_body}} ->
            parse_spider_response(response_body)

          {:ok, %{status: status}} ->
            {:error, {:http_error, status}}

          {:error, reason} ->
            {:error, {:transport_error, reason}}
        end
    end
  end

  defp parse_spider_response(body) when is_list(body) do
    case body do
      [%{"content" => content} | _] when is_binary(content) ->
        {:ok, content}

      _ ->
        {:error, :empty_spider_response}
    end
  end

  defp parse_spider_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_spider_response(decoded)
      {:error, _} -> {:error, :invalid_spider_response}
    end
  end

  defp parse_spider_response(_body), do: {:error, :invalid_spider_response}

  defp build_req(_url, auth_headers) do
    headers = normalize_headers(auth_headers)
    Req.new(headers: headers, receive_timeout: 30_000)
  end

  defp normalize_headers(headers) when is_list(headers), do: headers
  defp normalize_headers(_), do: []

  defp classify_content_type(value) when is_binary(value) do
    cond do
      String.contains?(value, "text/html") -> :html
      String.contains?(value, "application/xhtml") -> :html
      String.contains?(value, "application/json") -> :json
      String.contains?(value, "text/json") -> :json
      String.contains?(value, "application/xml") -> :xml
      String.contains?(value, "text/xml") -> :xml
      true -> :other
    end
  end

  defp classify_content_type(_), do: :other
end
