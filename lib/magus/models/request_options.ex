defmodule Magus.Models.RequestOptions do
  @moduledoc """
  Resolves a Magus model key into the ReqLLM model input plus per-request
  options (api_key, base_url) from the model's Provider row.

  - Unknown keys resolve to themselves with no extra options, so ReqLLM's
    env-var key convention keeps working (hosted behavior unchanged).
  - Custom OpenAI-compatible providers resolve to an inline model map
    (bypasses the LLMDB spec lookup) with base_url/api_key options.

  Lookups hit the DB per call; callers are LLM requests (network-bound),
  so this is acceptable. Add caching only if profiling demands it.
  """

  require Logger

  @type reqllm_model :: String.t() | map()

  @doc "Full resolution: the ReqLLM model input and request options."
  @spec resolve(String.t()) :: {reqllm_model(), keyword()}
  def resolve(model_key) when is_binary(model_key) do
    case lookup(model_key) do
      nil ->
        {model_key, []}

      {model, provider} ->
        opts =
          []
          |> maybe_put(:api_key, provider.api_key)
          |> maybe_put(:base_url, provider.base_url)

        if provider.req_llm_id == "openai_compatible" do
          {%{provider: :openai_compatible, id: strip_slug(model.key, provider.slug)}, opts}
        else
          {model.key, opts}
        end
    end
  end

  defp lookup(model_key) do
    case Magus.Chat.get_model_by_key_with_provider(model_key) do
      {:ok, %{model_provider: %{enabled?: true} = provider} = model} ->
        {model, provider}

      # disabled provider or no provider linked — intentional env fallback
      {:ok, _} ->
        nil

      {:error, error} ->
        # Not-found is the normal path for utility specs that live outside the
        # DB catalog; anything else (pool exhaustion, DB down) must be visible
        # because a custom provider would silently lose its credentials.
        unless not_found?(error) do
          Logger.warning(
            "RequestOptions lookup failed for #{model_key}: #{Exception.message(error)}"
          )
        end

        nil
    end
  end

  defp not_found?(%{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))
  end

  defp not_found?(_), do: false

  defp strip_slug(key, slug) do
    String.replace_prefix(key, slug <> ":", "")
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
