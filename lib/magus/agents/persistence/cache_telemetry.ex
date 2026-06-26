defmodule Magus.Agents.Persistence.CacheTelemetry do
  @moduledoc """
  Lightweight, best-effort prompt-cache-hit observability.

  Makes prompt-cache effectiveness visible so we can confirm `cached_tokens`
  moves from ~0 to >0 on repeat turns once Tier 1 prompt-cache work (system-prompt
  reorder + sticky `openrouter_session_id`) lands.

  This module is purely about *emitting a readout* — it does NOT change what gets
  persisted. `MessageUsage.cached_tokens` is already persisted separately by
  `Magus.Usage.MessageUsage.Changes.ExtractTokens`; the cached/prompt extraction
  here mirrors that change's precedence so the readout matches the stored value.

  Emits two signals per normal text-generation response:

    * a `Logger.info` line for manual cache validation
    * a `[:magus, :agents, :prompt_cache]` `:telemetry` event for future dashboards

  Both are best-effort: a logging/telemetry failure must never disrupt usage
  recording, so `emit/2` rescues everything and returns `:ok`.
  """

  require Logger

  @telemetry_event [:magus, :agents, :prompt_cache]

  @doc """
  Cache-hit ratio as `cached / prompt`, clamped to `0.0..1.0`.

  Returns `0.0` when `prompt_tokens` is `0` or `nil` (no division by zero), and
  `0.0` when `cached_tokens` is `nil`. A full hit (`cached == prompt`) is `1.0`.

  Pure and DB-free.

  ## Examples

      iex> Magus.Agents.Persistence.CacheTelemetry.cache_hit_ratio(50, 100)
      0.5

      iex> Magus.Agents.Persistence.CacheTelemetry.cache_hit_ratio(0, 100)
      0.0

      iex> Magus.Agents.Persistence.CacheTelemetry.cache_hit_ratio(100, 100)
      1.0

      iex> Magus.Agents.Persistence.CacheTelemetry.cache_hit_ratio(10, 0)
      0.0

      iex> Magus.Agents.Persistence.CacheTelemetry.cache_hit_ratio(10, nil)
      0.0
  """
  @spec cache_hit_ratio(non_neg_integer() | nil, non_neg_integer() | nil) :: float()
  def cache_hit_ratio(_cached_tokens, prompt_tokens)
      when is_nil(prompt_tokens) or prompt_tokens == 0,
      do: 0.0

  def cache_hit_ratio(cached_tokens, prompt_tokens)
      when is_number(cached_tokens) and is_number(prompt_tokens) and prompt_tokens > 0 do
    ratio = cached_tokens / prompt_tokens

    cond do
      ratio < 0.0 -> 0.0
      ratio > 1.0 -> 1.0
      true -> ratio
    end
  end

  def cache_hit_ratio(_cached_tokens, _prompt_tokens), do: 0.0

  @doc """
  Extracts the prompt-token count from a raw provider usage map.

  Mirrors `ExtractTokens.set_core_tokens/2` precedence so the readout matches
  the persisted `MessageUsage.prompt_tokens`. Returns `0` when absent.
  """
  @spec prompt_tokens(map() | nil) :: non_neg_integer()
  def prompt_tokens(usage) when is_map(usage) do
    usage[:input_tokens] || usage[:prompt_tokens] || usage[:input] ||
      usage["prompt_tokens"] || usage["input_tokens"] || 0
  end

  def prompt_tokens(_usage), do: 0

  @doc """
  Extracts the cached-token count from a raw provider usage map.

  Mirrors `ExtractTokens.set_prompt_details/3` precedence (top-level ReqLLM
  normalized keys, then nested `prompt_tokens_details`) so the readout matches
  the persisted `MessageUsage.cached_tokens`. Returns `0` when absent.
  """
  @spec cached_tokens(map() | nil) :: non_neg_integer()
  def cached_tokens(usage) when is_map(usage) do
    details = usage["prompt_tokens_details"] || usage[:prompt_tokens_details] || %{}

    usage[:cached_input] || usage[:cached_tokens] ||
      details["cached_tokens"] || details[:cached_tokens] || 0
  end

  def cached_tokens(_usage), do: 0

  @doc """
  Best-effort emit of a prompt-cache readout for a single text-generation response.

  Logs an info line and fires the `#{inspect(@telemetry_event)}` telemetry event.

  Only fires when a prompt-token count is present (`prompt_tokens > 0`); skips
  cleanly for image/video generation and any usage shape without prompt tokens —
  no log spam, no telemetry with garbage measurements.

  Wrapped in a rescue so a logging/telemetry failure can never disrupt usage
  recording. Always returns `:ok`.

  `meta` accepts `:conversation_id` and `:model` for log context and telemetry
  metadata.
  """
  @spec emit(map() | nil, keyword()) :: :ok
  def emit(usage, meta \\ []) do
    prompt = prompt_tokens(usage)

    if is_integer(prompt) and prompt > 0 do
      cached = cached_tokens(usage)
      ratio = cache_hit_ratio(cached, prompt)

      conversation_id = Keyword.get(meta, :conversation_id)
      model = Keyword.get(meta, :model)

      Logger.info(
        "prompt cache: cached=#{cached}/#{prompt} (#{format_pct(ratio)}%) " <>
          "conv=#{inspect(conversation_id)} model=#{inspect(model)}"
      )

      :telemetry.execute(
        @telemetry_event,
        %{cached_tokens: cached, prompt_tokens: prompt, ratio: ratio},
        %{conversation_id: conversation_id, model: model}
      )
    end

    :ok
  rescue
    e ->
      Logger.debug("prompt cache telemetry skipped: #{Exception.message(e)}")
      :ok
  end

  defp format_pct(ratio) when is_float(ratio) do
    (ratio * 100) |> Float.round(1)
  end
end
