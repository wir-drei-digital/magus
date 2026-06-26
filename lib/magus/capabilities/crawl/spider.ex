defmodule Magus.Capabilities.Crawl.Spider do
  @moduledoc """
  Spider.cloud crawl/scrape adapter. Opt-in via `SPIDER_API_KEY`; `configured?/0`
  returns false (and the dispatcher gates the tool off) when the key is absent.

  Honors `:magus, :spider_req_options` for request injection (used by tests via
  `Req.Test`).
  """
  @behaviour Magus.Capabilities.Crawl.Provider

  require Logger

  @base_url "https://api.spider.cloud/v1"
  @default_timeout 120_000
  @max_retries 2
  @retryable_statuses [429, 500, 502, 503, 504]

  @default_crawl_depth 0
  @default_crawl_limit 10
  @default_return_format "markdown"
  @default_max_content_length 20_000

  @impl true
  def configured?, do: not is_nil(System.get_env("SPIDER_API_KEY"))

  @impl true
  def fetch(urls, opts) do
    case System.get_env("SPIDER_API_KEY") do
      nil ->
        {:error, :not_configured}

      api_key ->
        crawl_depth = Keyword.get(opts, :crawl_depth) || @default_crawl_depth
        crawl_limit = Keyword.get(opts, :crawl_limit) || @default_crawl_limit
        return_format = Keyword.get(opts, :return_format) || @default_return_format
        max_content_length = Keyword.get(opts, :max_content_length) || @default_max_content_length
        mode = if crawl_depth > 0, do: :crawl, else: :scrape

        do_fetch(urls, mode, crawl_depth, crawl_limit, return_format, max_content_length, api_key)
    end
  end

  defp do_fetch(urls, mode, crawl_depth, crawl_limit, return_format, max_content_length, api_key) do
    body =
      %{url: Enum.join(urls, ","), return_format: return_format, metadata: true}
      |> maybe_add_crawl_params(mode, crawl_depth, crawl_limit)

    endpoint = if mode == :crawl, do: "/crawl", else: "/scrape"

    case execute_request(build_request(endpoint, body, api_key)) do
      {:ok, response_body} -> {:ok, parse_results(response_body, max_content_length)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_add_crawl_params(body, :crawl, depth, limit) do
    body
    |> Map.put(:depth, depth)
    |> Map.put(:limit, limit)
  end

  defp maybe_add_crawl_params(body, :scrape, _depth, _limit), do: body

  # Spider may return a raw JSON string if Content-Type isn't application/json
  defp parse_results(body, max_content_length) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        parse_results(decoded, max_content_length)

      {:error, _} ->
        Logger.warning("Spider API returned unparseable response: #{String.slice(body, 0, 500)}")
        []
    end
  end

  defp parse_results(results, max_content_length) when is_list(results) do
    Enum.map(results, fn result ->
      content = result["content"]

      truncated_content =
        if max_content_length > 0 && is_binary(content) &&
             byte_size(content) > max_content_length do
          String.slice(content, 0, max_content_length) <>
            "\n\n[Content truncated at #{max_content_length} characters]"
        else
          content
        end

      metadata = result["metadata"] || %{}

      %{
        url: result["url"],
        status: result["status"],
        title: metadata["title"],
        description: metadata["description"],
        content: truncated_content,
        error: result["error"]
      }
    end)
  end

  defp parse_results(%{"error" => error}, _max_content_length) do
    [%{url: nil, status: nil, title: nil, content: nil, error: error}]
  end

  defp parse_results(unexpected, _max_content_length) do
    Logger.warning(
      "Spider API returned unexpected response format: #{inspect(unexpected, limit: 500)}"
    )

    []
  end

  defp build_request(endpoint, body, api_key) do
    base_opts = [
      url: "#{@base_url}#{endpoint}",
      method: :post,
      json: body,
      headers: [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"}
      ],
      receive_timeout: @default_timeout,
      connect_options: [timeout: @default_timeout]
    ]

    extra_opts = Application.get_env(:magus, :spider_req_options, [])
    Req.new(Keyword.merge(base_opts, extra_opts))
  end

  defp execute_request(req), do: execute_with_retry(req, 0)

  defp execute_with_retry(req, attempt) do
    case Req.request(req) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: _body}}
      when status in @retryable_statuses and attempt < @max_retries ->
        Logger.warning("Spider API returned #{status}, retrying",
          retries_left: @max_retries - attempt
        )

        Process.sleep(1000 * (attempt + 1))
        execute_with_retry(req, attempt + 1)

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Spider API error", status: status, body: inspect(body))
        {:error, {:http_error, status, body}}

      {:error, %Req.TransportError{reason: reason}} when attempt < @max_retries ->
        Logger.warning("Spider API transport error, retrying",
          reason: inspect(reason),
          retries_left: @max_retries - attempt
        )

        Process.sleep(1000 * (attempt + 1))
        execute_with_retry(req, attempt + 1)

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        {:error, {:unknown_error, reason}}
    end
  end
end
