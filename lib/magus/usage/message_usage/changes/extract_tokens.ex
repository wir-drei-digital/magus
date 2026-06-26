defmodule Magus.Usage.MessageUsage.Changes.ExtractTokens do
  @moduledoc """
  Extracts token counts from raw LLM usage data.

  This change parses the usage map from provider responses and sets
  the appropriate token count attributes. Cost calculation is handled
  by the caller (e.g., UsageRecorder).
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    usage = Ash.Changeset.get_argument(changeset, :usage) || %{}

    # Extract detailed token info from OpenRouter/provider response (handle both atom and string keys)
    completion_details =
      usage["completion_tokens_details"] || usage[:completion_tokens_details] || %{}

    prompt_details = usage["prompt_tokens_details"] || usage[:prompt_tokens_details] || %{}

    changeset
    |> set_core_tokens(usage)
    |> set_completion_details(usage, completion_details)
    |> set_prompt_details(usage, prompt_details)
  end

  defp set_core_tokens(changeset, usage) do
    # Handle both atom and string keys, and different naming conventions
    prompt_tokens =
      usage[:input_tokens] || usage[:prompt_tokens] || usage[:input] ||
        usage["prompt_tokens"] || usage["input_tokens"] || 0

    completion_tokens =
      usage[:output_tokens] || usage[:completion_tokens] || usage[:output] ||
        usage["completion_tokens"] || usage["output_tokens"] || 0

    total_tokens =
      usage[:total_tokens] || usage["total_tokens"] || prompt_tokens + completion_tokens

    changeset
    |> Ash.Changeset.change_attribute(:prompt_tokens, prompt_tokens)
    |> Ash.Changeset.change_attribute(:completion_tokens, completion_tokens)
    |> Ash.Changeset.change_attribute(:total_tokens, total_tokens)
  end

  defp set_completion_details(changeset, usage, details) do
    # Reasoning tokens can be at top level (ReqLLM normalized) or in details
    reasoning_tokens =
      usage[:reasoning] || usage[:reasoning_tokens] ||
        details["reasoning_tokens"] || details[:reasoning_tokens]

    changeset
    |> Ash.Changeset.change_attribute(:reasoning_tokens, reasoning_tokens)
    |> Ash.Changeset.change_attribute(
      :audio_tokens,
      details["audio_tokens"] || details[:audio_tokens]
    )
    |> Ash.Changeset.change_attribute(
      :accepted_prediction_tokens,
      details["accepted_prediction_tokens"] || details[:accepted_prediction_tokens]
    )
    |> Ash.Changeset.change_attribute(
      :rejected_prediction_tokens,
      details["rejected_prediction_tokens"] || details[:rejected_prediction_tokens]
    )
  end

  defp set_prompt_details(changeset, usage, details) do
    # Cached tokens can be at top level (ReqLLM normalized) or in details
    cached_tokens =
      usage[:cached_input] || usage[:cached_tokens] ||
        details["cached_tokens"] || details[:cached_tokens] || 0

    cache_write_tokens =
      usage[:cache_creation] || usage[:cache_write_tokens] ||
        details["cache_write_tokens"] || details[:cache_write_tokens] || 0

    changeset
    |> Ash.Changeset.change_attribute(:cached_tokens, cached_tokens)
    |> Ash.Changeset.change_attribute(:cache_write_tokens, cache_write_tokens)
    |> Ash.Changeset.change_attribute(
      :prompt_audio_tokens,
      details["audio_tokens"] || details[:audio_tokens]
    )
    |> Ash.Changeset.change_attribute(
      :video_tokens,
      details["video_tokens"] || details[:video_tokens]
    )
  end
end
