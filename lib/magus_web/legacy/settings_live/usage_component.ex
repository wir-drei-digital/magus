defmodule MagusWeb.SettingsLive.UsageComponent do
  @moduledoc """
  Component that displays usage statistics and progress bars for subscription limits.

  Shows:
  - Pay-as-you-go spend this billing period in CHF (vs the monthly cap)
  - Tokens used this period
  - Storage used
  """
  use MagusWeb, :live_component

  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <h3 class="text-lg font-semibold">{gettext("Current Usage")}</h3>

      <.usage_bar
        label={if @money[:trial], do: gettext("Free trial usage"), else: gettext("Spent this period")}
        current={@money.spent_cents}
        limit={@money.cap_cents}
        format={:chf}
        reset_text={
          if @money[:trial],
            do: gettext("Your one-time allowance to try Magus — subscribe for a monthly budget"),
            else: gettext("Resets with your billing period")
        }
      />

      <div class="flex flex-wrap gap-x-6 gap-y-1 text-sm text-base-content/70">
        <span>
          {gettext("Tokens used")}:
          <span class="font-medium">{format_tokens(@money.tokens_used)}</span>
        </span>
      </div>

      <.usage_bar
        label={gettext("Storage")}
        current={@storage_used}
        limit={@limits.storage_bytes}
        format={:bytes}
      />

      <.storage_overage_warning
        :if={@storage_used > @limits.storage_bytes}
        used={@storage_used}
        limit={@limits.storage_bytes}
      />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :current, :integer, required: true
  attr :limit, :integer, default: nil
  attr :reset_text, :string, default: nil
  attr :format, :atom, default: :number

  defp usage_bar(assigns) do
    percentage = calculate_percentage(assigns.current, assigns.limit)
    color = usage_color(percentage)

    assigns = assign(assigns, percentage: percentage, color: color)

    ~H"""
    <div>
      <div class="flex justify-between text-sm mb-1">
        <span>{@label}</span>
        <span class="font-medium">
          {format_value(@current, @format)} / {format_limit(@limit, @format)}
        </span>
      </div>
      <div class="w-full bg-base-300 rounded-full h-2.5">
        <div
          class={"h-2.5 rounded-full transition-all duration-300 #{@color}"}
          style={"width: #{@percentage}%"}
        >
        </div>
      </div>
      <p :if={@reset_text} class="text-xs text-base-content/60 mt-1">
        {@reset_text}
      </p>
    </div>
    """
  end

  attr :used, :integer, required: true
  attr :limit, :integer, required: true

  defp storage_overage_warning(assigns) do
    ~H"""
    <div class="alert alert-warning">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        class="stroke-current shrink-0 h-6 w-6"
        fill="none"
        viewBox="0 0 24 24"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
        />
      </svg>
      <span>
        {gettext(
          "You are over your storage limit (%{used} / %{limit}). Please delete files or upgrade within 30 days.",
          used: format_bytes(@used),
          limit: format_bytes(@limit)
        )}
      </span>
    </div>
    """
  end

  defp calculate_percentage(_current, nil), do: 0
  defp calculate_percentage(_current, 0), do: 0

  defp calculate_percentage(current, limit),
    do: min(100.0, current / limit * 100) |> Float.round(1)

  defp usage_color(percentage) when percentage >= 100, do: "bg-error"
  defp usage_color(percentage) when percentage >= 80, do: "bg-warning"
  defp usage_color(_), do: "bg-success"

  defp format_value(value, :bytes), do: format_bytes(value)
  defp format_value(value, :chf), do: format_chf(value)
  defp format_value(value, :number), do: value

  defp format_limit(nil, :chf), do: gettext("No cap")
  defp format_limit(nil, _format), do: gettext("Unlimited")
  defp format_limit(limit, :bytes), do: format_bytes(limit)
  defp format_limit(limit, :chf), do: format_chf(limit)
  defp format_limit(limit, :number), do: limit

  defp format_chf(cents) when is_integer(cents),
    do: "CHF #{:erlang.float_to_binary(cents / 100, decimals: 2)}"

  defp format_chf(_), do: "CHF 0.00"

  defp format_tokens(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  defp format_tokens(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  defp format_tokens(n) when is_integer(n), do: Integer.to_string(n)
  defp format_tokens(_), do: "0"

  defp format_bytes(bytes), do: MagusWeb.Formatters.format_bytes(bytes)
end
