defmodule Magus.Agents.Tools.Web.WebFetch do
  @moduledoc """
  Web content fetching tool.

  Scrapes or crawls web pages via the configured crawl provider
  (`Magus.Capabilities.Crawl`, Spider by default), returning content as markdown.
  When `crawl_depth` is 0 (default), uses a single-page scrape; when > 0, crawls
  linked pages up to the specified depth.

  ## Configuration

  Requires a configured crawl provider (Spider: `SPIDER_API_KEY`). The tool is
  gated off during agent tool registration when no provider is configured.

  ## Usage with Jido AI

      tools = [Magus.Agents.Tools.Web.WebFetch]
  """

  use Jido.Action,
    name: "web_fetch",
    description: """
    Fetch the contents of one or more web pages. Use this to read articles, documentation,
    or any web content when you have specific URLs. Returns page content as markdown.
    Set crawl_depth > 0 to crawl linked pages from the given URLs up to that depth.
    """,
    schema: [
      urls: [
        type: {:list, :string},
        required: true,
        doc: "List of URLs to fetch (1-10 URLs)"
      ],
      crawl_depth: [
        type: :integer,
        required: false,
        doc:
          "Crawl depth. 0 = scrape only (default), 1+ = follow links to that depth. Use crawl for sitemaps or multi-page docs."
      ],
      crawl_limit: [
        type: :integer,
        required: false,
        doc: "Maximum number of pages to return when crawling (default: 10)"
      ],
      return_format: [
        type: {:in, ["markdown", "commonmark", "text", "raw", "xml"]},
        required: false,
        doc: "Content format: markdown (default), commonmark, text, raw, xml"
      ],
      max_content_length: [
        type: :integer,
        required: false,
        doc: "Maximum characters of content per page (default: 20000). Set to 0 for unlimited."
      ]
    ]

  require Logger

  alias Magus.Agents.Signals
  alias Magus.Agents.Tools.Web.UrlHelpers
  alias Magus.Capabilities.Crawl

  @min_urls 1
  @max_urls 10
  @default_crawl_depth 0
  @default_crawl_limit 10
  @default_return_format "markdown"
  @default_max_content_length 20_000

  @doc "User-friendly display name shown in the UI when this tool is executing"
  def display_name, do: "Fetching web pages..."

  @doc "Generate a human-readable summary of the tool output for UI display"
  def summarize_output(%{results: results}) when is_list(results) do
    count = length(results)

    if count == 1 do
      "Fetched 1 page"
    else
      "Fetched #{count} pages"
    end
  end

  def summarize_output(%{error: error}), do: "Error: #{error}"
  def summarize_output(_), do: "Fetch completed"

  @doc "System prompt context explaining when and how to use this tool"
  def system_prompt_context do
    """
    - web_fetch: Fetch the content of specific URLs. Use this when you need to read the content
      of a web page that the user has provided or that you found from a web search.
      You can fetch up to 10 URLs at once. Set crawl_depth > 0 to crawl linked pages.
    """
  end

  @impl true
  def run(params, context) do
    urls = get_param(params, "urls") || []
    crawl_depth = get_param(params, "crawl_depth", @default_crawl_depth)
    crawl_limit = get_param(params, "crawl_limit", @default_crawl_limit)
    return_format = get_param(params, "return_format", @default_return_format)
    max_content_length = get_param(params, "max_content_length", @default_max_content_length)

    case validate_urls(urls) do
      :ok ->
        mode = if crawl_depth > 0, do: :crawl, else: :scrape

        Signals.emit_tool_progress(context, :fetching, %{
          mode: mode,
          count: length(urls),
          urls: Enum.take(urls, 3)
        })

        fetch_opts = [
          crawl_depth: crawl_depth,
          crawl_limit: crawl_limit,
          return_format: return_format,
          max_content_length: max_content_length
        ]

        case Crawl.fetch(urls, fetch_opts) do
          {:ok, results} ->
            emit_page_progress(results, context)
            {:ok, %{urls: urls, mode: mode, results: results}}

          {:error, reason} ->
            error_message = format_api_error(reason)
            Logger.error("WebFetch failed", urls: urls, error: error_message)
            {:ok, %{error: error_message, urls: urls, results: []}}
        end

      {:error, reason} ->
        error_message = format_validation_error(reason)
        Logger.warning("WebFetch validation failed", urls: urls, error: error_message)
        {:ok, %{error: error_message, urls: urls, results: []}}
    end
  end

  defp emit_page_progress(results, context) do
    Enum.with_index(results, 1)
    |> Enum.each(fn {result, index} ->
      Signals.emit_tool_progress(context, :page_fetched, %{
        index: index,
        total: length(results),
        url: result.url,
        title: result[:title]
      })
    end)
  end

  defp validate_urls(urls) when is_list(urls) do
    count = length(urls)

    cond do
      count < @min_urls ->
        {:error, :empty_urls}

      count > @max_urls ->
        {:error, :too_many_urls}

      not Enum.all?(urls, &UrlHelpers.valid_url?/1) ->
        invalid = Enum.reject(urls, &UrlHelpers.valid_url?/1)
        {:error, {:invalid_urls, invalid}}

      true ->
        :ok
    end
  end

  defp validate_urls(_), do: {:error, :empty_urls}

  # Error formatting

  defp format_api_error({:http_error, status, _body}), do: "Spider API returned HTTP #{status}"
  defp format_api_error({:transport_error, reason}), do: "Network error: #{inspect(reason)}"
  defp format_api_error({:unknown_error, reason}), do: "Error: #{inspect(reason)}"

  # Names the default provider's key (Spider); the dispatcher gates the tool off
  # entirely when no crawl provider is configured.
  defp format_api_error(:not_configured),
    do: "Web crawling is not configured (set SPIDER_API_KEY)"

  defp format_api_error(reason), do: "Error: #{inspect(reason)}"

  defp format_validation_error(:empty_urls), do: "You must provide at least one URL"

  defp format_validation_error(:too_many_urls),
    do: "You can fetch a maximum of #{@max_urls} URLs at once"

  defp format_validation_error({:invalid_urls, urls}) do
    "Invalid URL format: #{Enum.join(urls, ", ")}"
  end

  defp format_validation_error(reason), do: "Validation error: #{inspect(reason)}"

  # Get param by string key, falling back to atom key for compatibility
  defp get_param(params, key, default \\ nil) when is_binary(key) do
    case Map.get(params, key) do
      nil ->
        case Map.fetch(params, String.to_existing_atom(key)) do
          {:ok, val} -> val
          :error -> default
        end

      val ->
        val
    end
  rescue
    ArgumentError -> default
  end
end
