defmodule Magus.Agents.AttachmentLimits do
  @moduledoc """
  Single source of truth for per-agent attachment limits.

  Hard caps (block the action):
  - max_attachments_per_agent: total across both modes
  - max_always_include_tokens: sum of token_count across :always-mode attachments
  - max_total_size_bytes: sum of file_size across all attachments

  Soft thresholds (UI warning only):
  - always_include_warning_threshold: amber state below the hard token cap
  """

  @max_attachments 20
  @max_always_tokens 30_000
  @warn_always_tokens 20_000
  @max_size_bytes 100 * 1024 * 1024

  def max_attachments_per_agent, do: @max_attachments
  def max_always_include_tokens, do: @max_always_tokens
  def always_include_warning_threshold, do: @warn_always_tokens
  def max_total_size_bytes, do: @max_size_bytes

  def exceeds_attachment_count?(count) when is_integer(count),
    do: count > @max_attachments

  def exceeds_always_include_tokens?(tokens) when is_integer(tokens),
    do: tokens > @max_always_tokens

  def exceeds_total_size?(bytes) when is_integer(bytes),
    do: bytes > @max_size_bytes
end
