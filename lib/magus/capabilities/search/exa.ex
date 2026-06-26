defmodule Magus.Capabilities.Search.Exa do
  @moduledoc """
  Exa.ai web-search adapter. Opt-in via `EXA_API_KEY`; `configured?/0` returns
  false (and the dispatcher gates the tool off) when the key is absent.

  Self-contained transport (like the Spider crawl adapter): owns its base URL,
  request building, and retry logic. Honors `:magus, :exa_req_options` for
  request injection (used by tests via `Req.Test`).
  """
  @behaviour Magus.Capabilities.Search.Provider

  require Logger

  @base_url "https://api.exa.ai"
  @default_timeout 60_000
  @max_retries 2

  @default_num_results 5
  @max_results 10

  @impl true
  def configured?, do: api_key() != nil

  @impl true
  def search(query, opts) do
    num_results = min(Keyword.get(opts, :num_results) || @default_num_results, @max_results)
    category = Keyword.get(opts, :category)
    do_search(query, num_results, category)
  end

  defp do_search(query, num_results, category) do
    body =
      %{query: query, numResults: num_results, type: "auto", contents: %{summary: true}}
      |> maybe_add_category(category)

    case execute_request(build_request("/search", body)) do
      {:ok, response_body} -> {:ok, parse_results(response_body)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_add_category(body, nil), do: body

  defp maybe_add_category(body, category) when is_binary(category),
    do: Map.put(body, :category, category)

  defp parse_results(%{"results" => results}) when is_list(results) do
    Enum.map(results, fn result ->
      %{
        title: result["title"],
        url: result["url"],
        summary: result["summary"],
        published_date: result["publishedDate"]
      }
    end)
  end

  defp parse_results(_), do: []

  # ---------------------------------------------------------------------------
  # HTTP transport (self-contained; was Magus.Agents.Tools.Web.Helpers)
  # ---------------------------------------------------------------------------

  defp api_key, do: System.get_env("EXA_API_KEY")

  defp build_request(endpoint, body) do
    base_opts = [
      url: "#{@base_url}#{endpoint}",
      method: :post,
      json: body,
      headers: [
        {"x-api-key", api_key()},
        {"Content-Type", "application/json"}
      ],
      receive_timeout: @default_timeout,
      connect_options: [timeout: @default_timeout]
    ]

    extra_opts = Application.get_env(:magus, :exa_req_options, [])
    Req.new(Keyword.merge(base_opts, extra_opts))
  end

  defp execute_request(req), do: execute_with_retry(req, 0)

  defp execute_with_retry(req, attempt) do
    case Req.request(req) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Exa API error", status: status, body: inspect(body))
        {:error, {:http_error, status, body}}

      {:error, %Req.TransportError{reason: reason}} when attempt < @max_retries ->
        Logger.warning("Exa API transport error, retrying",
          reason: inspect(reason),
          retries_left: @max_retries - attempt
        )

        Process.sleep(1000)
        execute_with_retry(req, attempt + 1)

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        {:error, {:unknown_error, reason}}
    end
  end
end
