defmodule Magus.Brain.SourceIngester do
  @moduledoc """
  HTTP fetch + HTML text/title extraction helpers used by
  `Magus.Brain.Source.IngestWorker`.

  Phase C4 retired the old block-writing flow (`create_child_blocks/3`)
  — sources are now first-class `Magus.Brain.Source` rows and the
  worker writes `ingested_content` directly. The helpers in this module
  stayed because they're pure (no Brain coupling) and the IngestWorker
  reuses them.
  """

  require Logger

  @doc """
  Fetches a URL and extracts text content and title from the response body.

  Returns `{:ok, %{title: string | nil, content: string}}` or `{:error, reason}`.

  Extra Req options can be injected via the `:brain_source_req_options`
  app env (used in tests to swap in a `Req.Test` plug).
  """
  def fetch_url(url) do
    base_opts = [
      url: url,
      redirect: true,
      max_redirects: 5,
      receive_timeout: 15_000
    ]

    extra_opts = Application.get_env(:magus, :brain_source_req_options, [])

    case base_opts |> Keyword.merge(extra_opts) |> Req.new() |> Req.get() do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        content = extract_text_from_html(body)
        title = extract_title_from_html(body)
        {:ok, %{title: title, content: content}}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Extracts a display title from a source block's content map.

  Falls back through content["title"] -> content["text"] -> "Untitled Source".
  """
  def extract_title(%{"title" => title}) when is_binary(title) and title != "", do: title
  def extract_title(%{"text" => text}) when is_binary(text) and text != "", do: text
  def extract_title(_), do: "Untitled Source"

  defp extract_text_from_html(body) when is_binary(body) do
    body
    |> String.replace(~r/<script[^>]*>.*?<\/script>/is, "")
    |> String.replace(~r/<style[^>]*>.*?<\/style>/is, "")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 50_000)
  end

  defp extract_text_from_html(_), do: ""

  defp extract_title_from_html(body) when is_binary(body) do
    case Regex.run(~r/<title[^>]*>(.*?)<\/title>/is, body) do
      [_, title] -> String.trim(title)
      _ -> nil
    end
  end

  defp extract_title_from_html(_), do: nil
end
