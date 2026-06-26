defmodule Magus.Eval.Benchmarks.LongMemEval.Loader do
  @moduledoc """
  Loads the LongMemEval-S dataset. Prefers an explicit/cached local file so the
  benchmark is runnable by dropping the dataset on disk; falls back to an
  optional HTTP download into the cache. Returns {:error, :no_dataset} when
  neither is available so live tests can skip gracefully.
  """
  require Logger

  @cache_rel "eval/cache/longmemeval_s.json"

  def load(opts \\ []) do
    path =
      opts[:path] || System.get_env("EVAL_LONGMEMEVAL_PATH") || Path.join(File.cwd!(), @cache_rel)

    cond do
      File.exists?(path) ->
        decode(path)

      url = Keyword.get(opts, :url, System.get_env("EVAL_LONGMEMEVAL_URL")) ->
        download_then_decode(url, path)

      true ->
        {:error, :no_dataset}
    end
  end

  defp decode(path) do
    with {:ok, body} <- File.read(path), {:ok, data} when is_list(data) <- Jason.decode(body) do
      {:ok, data}
    else
      _ -> {:error, :bad_dataset}
    end
  end

  defp download_then_decode(url, path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, %{status: 200, body: body}} <- Req.get(url),
         :ok <- File.write(path, if(is_binary(body), do: body, else: Jason.encode!(body))) do
      decode(path)
    else
      other ->
        Logger.warning("LongMemEval download failed: #{inspect(other)}")
        {:error, :no_dataset}
    end
  end
end
