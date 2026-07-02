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

  @doc """
  Full resolution with no actor: delegates to `resolve/2` with a `nil` actor.

  A `nil` actor never receives owned-provider credentials, so every existing
  caller stays on the safe (global-only) path until it is threaded an actor.
  """
  @spec resolve(String.t()) :: {reqllm_model(), keyword()}
  def resolve(model_key) when is_binary(model_key), do: resolve(model_key, nil)

  @doc """
  Actor-aware resolution. Fail-closed: an owned provider's credentials are
  returned only to its owner. A non-owner or a missing actor gets the safe
  fallback `{model_key, []}` (no api_key, no base_url) and an `:owner_mismatch`
  telemetry event carrying only the `provider_id`, never the key.
  """
  @spec resolve(String.t(), binary() | nil) :: {reqllm_model(), keyword()}
  def resolve(model_key, actor_id) when is_binary(model_key) do
    case lookup(model_key) do
      nil ->
        {model_key, []}

      {model, provider} ->
        if authorized?(provider, actor_id) do
          opts =
            []
            |> maybe_put(:api_key, provider.api_key)
            |> maybe_put(:base_url, provider.base_url)

          {reqllm_model(model, provider), opts}
        else
          :telemetry.execute(
            [:magus, :models, :request_options, :owner_mismatch],
            %{count: 1},
            %{provider_id: provider.id}
          )

          {model_key, []}
        end
    end
  end

  # Global providers serve anyone; owned providers serve only their owner.
  defp authorized?(%{owner_user_id: nil}, _actor_id), do: true
  defp authorized?(%{owner_user_id: owner}, actor_id), do: is_binary(actor_id) and owner == actor_id

  # openai_compatible bypasses the LLMDB spec lookup with an inline map; every
  # other provider resolves to "<req_llm_id>:<model-id-without-slug>", which is a
  # no-op for global built-ins (slug == req_llm_id) and the correct rewrite for
  # owned providers whose slug differs from req_llm_id.
  defp reqllm_model(model, %{req_llm_id: "openai_compatible"} = provider),
    do: %{provider: :openai_compatible, id: strip_slug(model.key, provider.slug)}

  defp reqllm_model(model, provider),
    do: provider.req_llm_id <> ":" <> strip_slug(model.key, provider.slug)

  defp lookup(model_key) do
    # Read as internal catalog plumbing: bypass the Provider read policy so the
    # full row (including a non-nil owner_user_id for owned providers) loads.
    # `authorized?/2` above is the sole owner gate; this lookup only fetches.
    case Magus.Chat.get_model_by_key_with_provider(model_key, authorize?: false) do
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
