defmodule Magus.Eval.Benchmarks.GAIA.Loader do
  @moduledoc """
  Loads the GAIA validation split (text-only handled by the adapter's cases/2).
  Prefers a local/cached file; otherwise attempts a gated HuggingFace fetch with
  a token. Returns {:error, :gaia_access} when neither is available so live tests
  skip gracefully. GAIA is a gated dataset: access requires accepting its terms
  and an HF token (env HF_TOKEN).
  """
  require Logger

  @cache_rel "eval/cache/gaia_validation.json"

  def load(opts \\ []) do
    path = opts[:path] || System.get_env("EVAL_GAIA_PATH") || Path.join(File.cwd!(), @cache_rel)
    token = Keyword.get(opts, :token, System.get_env("HF_TOKEN"))
    url = Keyword.get(opts, :url, System.get_env("EVAL_GAIA_URL"))

    cond do
      File.exists?(path) ->
        decode(path)

      is_binary(token) and is_binary(url) ->
        fetch(url, token, path)

      true ->
        {:error, :gaia_access}
    end
  end

  defp decode(path) do
    with {:ok, body} <- File.read(path), {:ok, data} when is_list(data) <- Jason.decode(body) do
      {:ok, data}
    else
      _ -> {:error, :bad_dataset}
    end
  end

  defp fetch(url, token, path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, %{status: 200, body: body}} <-
           Req.get(url, headers: [{"authorization", "Bearer " <> token}]),
         :ok <- File.write(path, if(is_binary(body), do: body, else: Jason.encode!(body))) do
      decode(path)
    else
      other ->
        Logger.warning("GAIA download failed: #{inspect(other)}")
        {:error, :gaia_access}
    end
  end
end
