defmodule Magus.Files.EmbeddingModel do
  @moduledoc """
  Handles embedding generation using OpenRouter embeddings API.
  """

  require Logger

  @batch_size 100
  @default_receive_timeout 60_000

  @doc "The embedding model spec, resolved through the roles registry."
  def model, do: Magus.Models.Roles.resolve(:embeddings)

  @doc """
  Generates embeddings for a list of texts or a single text.
  Handles batching for large lists.

  Returns {:ok, embeddings} or {:error, reason}

  Options:

    * `:receive_timeout` — HTTP receive timeout in ms (default #{@default_receive_timeout}).
      Interactive callers on the per-message hot path should pass a short
      timeout so a slow provider degrades to no-context instead of blocking.
  """
  def embed(texts, opts \\ [])

  def embed(texts, opts) when is_list(texts) do
    if Enum.empty?(texts) do
      {:ok, []}
    else
      texts
      |> Enum.chunk_every(@batch_size)
      |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
        case embed_batch(batch, opts) do
          {:ok, embeddings} -> {:cont, {:ok, acc ++ embeddings}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  def embed(text, opts) when is_binary(text) do
    case embed([text], opts) do
      {:ok, [embedding]} -> {:ok, embedding}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Generates embedding for a query string (for similarity search).

  Accepts the same options as `embed/2`.
  """
  def embed_query(query, opts \\ []) when is_binary(query) do
    embed(query, opts)
  end

  defp embed_batch(texts, opts) do
    case get_api_key() do
      nil ->
        {:error,
         "OpenRouter API key not configured. Set OPENROUTER_API_KEY environment variable."}

      api_key ->
        do_embed_request(texts, api_key, opts)
    end
  end

  defp do_embed_request(texts, api_key, opts) do
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)
    url = "https://openrouter.ai/api/v1/embeddings"

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]

    body = %{"input" => texts, "model" => model()}

    case Req.post(url, json: body, headers: headers, receive_timeout: receive_timeout) do
      {:ok, %Req.Response{status: 200, body: %{"data" => data}}} ->
        embeddings =
          data
          |> Enum.sort_by(& &1["index"])
          |> Enum.map(& &1["embedding"])

        {:ok, embeddings}

      {:ok, %Req.Response{status: status, body: body}} ->
        error_message = get_in(body, ["error", "message"]) || "Unknown error"
        Logger.error("OpenRouter embedding API error (#{status}): #{error_message}")
        {:error, "OpenRouter API error: #{error_message}"}

      {:error, exception} ->
        Logger.error("OpenRouter embedding request failed: #{inspect(exception)}")
        {:error, "Request failed: #{inspect(exception)}"}
    end
  end

  defp get_api_key do
    System.get_env("OPENROUTER_API_KEY") ||
      Application.get_env(:magus, :openrouter_api_key)
  end
end
