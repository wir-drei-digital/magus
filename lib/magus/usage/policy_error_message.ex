defmodule Magus.Usage.PolicyErrorMessage do
  @moduledoc """
  Renders human-facing copy for a `Magus.Usage.PolicyError`. The structured error
  carries only data; this core renderer owns every string a user sees, so OSS and
  cloud editions can present different messaging from the same error.

  This module lives in CORE (not the web layer) so core modules can render
  user-facing limit copy without depending on `MagusWeb`. The web layer may still
  call this renderer (web -> core is fine).

  The clauses below were moved verbatim from the former
  `Magus.Usage.PolicyEnforcer.LimitExceeded.message/1`; the output is
  byte-identical to preserve what users see. `format_bytes/1` is reimplemented
  locally (byte-identical to `MagusWeb.Formatters.format_bytes/1`) to keep core
  web-free.
  """

  alias Magus.Usage.PolicyError

  @doc "Human-readable, user-facing message for a policy error."
  @spec message(PolicyError.t()) :: String.t()
  def message(%PolicyError{limit_type: :spend_cap, current: current, limit: limit}) do
    "You've reached your monthly spend cap (#{format_chf(current)}/#{format_chf(limit)}). " <>
      "Raise your cap (or turn it off) in Settings to keep going."
  end

  def message(%PolicyError{limit_type: :trial_cap, current: current, limit: limit}) do
    "You've used your free trial allowance (#{format_chf(current)}/#{format_chf(limit)}). " <>
      "Subscribe to Pay-as-you-go in Settings to keep going."
  end

  def message(%PolicyError{limit_type: :payment_required}) do
    "Your last payment failed. Update your payment method to keep using pay-as-you-go."
  end

  def message(%PolicyError{limit_type: :mode_disabled}) do
    "This feature is not available on your current plan. Upgrade to access it."
  end

  def message(%PolicyError{limit_type: :storage_bytes, current: current, limit: limit}) do
    "Storage limit reached (#{format_bytes(current)}/#{format_bytes(limit)}). Upgrade for more storage."
  end

  def message(%PolicyError{limit_type: :storage_overage}) do
    "You're over your storage limit. Please delete files or upgrade to upload new files."
  end

  def message(%PolicyError{limit_type: :max_upload_bytes, limit: limit}) do
    "File too large. Maximum upload size is #{format_bytes(limit)}."
  end

  def message(%PolicyError{limit_type: :workspace_model_restricted}) do
    "This model is not allowed in the current workspace. Choose an allowed model or switch to a personal conversation."
  end

  # Byte-count → human-readable string. Reimplemented byte-identically from
  # `MagusWeb.Formatters.format_bytes/1` so core stays web-free.
  defp format_bytes(nil), do: "0 B"
  defp format_bytes(0), do: "0 B"

  defp format_bytes(n) when is_binary(n) do
    case Integer.parse(n) do
      {int, _} -> format_bytes(int)
      :error -> "0 B"
    end
  end

  defp format_bytes(bytes) when is_number(bytes) and bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"

  defp format_bytes(bytes) when is_number(bytes) and bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp format_bytes(bytes) when is_number(bytes) and bytes >= 1024,
    do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_bytes(bytes) when is_number(bytes), do: "#{bytes} B"
  defp format_bytes(_), do: "0 B"

  # Integer cents (CHF) → "CHF 12.34"
  defp format_chf(nil), do: "CHF 0.00"

  defp format_chf(cents) when is_integer(cents) do
    "CHF " <> :erlang.float_to_binary(cents / 100, decimals: 2)
  end
end
