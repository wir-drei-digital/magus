defmodule MagusWeb.ChatLive.Components.ChatInput.ContextIndicatorComponent do
  @moduledoc """
  Context-window donut + breakdown panel.

  Reads the persisted `Magus.Chat.ContextWindow` snapshot (or `nil`) plus the
  selected model and renders an SVG ring whose fill is
  `last_total_tokens / last_max_context`, colored by the warn/alert thresholds
  from `Magus.Chat.ContextWindow.config/1`. The `dropdown-top` panel lists the
  per-category breakdown and carries the strategy toggle, Clear, and Compact
  controls.

  The controls use plain `phx-click` (no `phx-target`) so the events bubble past
  the nested live_components up to the owning `ConversationView` LiveView, which
  calls the owner-gated `Magus.Chat` actions. `data-role` hooks:

    - `data-role="context-donut"`             — the dropdown root (carries `data-context-fill`)
    - `data-role="context-total"`             — the "total / max tokens (pct%)" line
    - `data-role="context-breakdown"`         — the `<ul>` of category rows
    - `data-role="context-strategy-rolling"`  — strategy toggle button (rolling)
    - `data-role="context-strategy-compact"`  — strategy toggle button (compact)
    - `data-role="context-compact"`           — request-compaction button (carries `data-compaction-status`)
    - `data-role="context-clear"`             — clear-the-window button

  The strategy / Compact / Clear control row only renders for the conversation
  owner (`is_owner`, nil-safe default `false`). Non-owners (accepted multiplayer
  members, workspace grantees) get the read-only donut + breakdown without the
  controls, mirroring the owner-gated `Magus.Chat` actions.

  The Compact button is disabled while a compaction is in flight
  (`compaction_status in [:pending, :running]`); when `:failed` it stays
  enabled and acts as a retry. Status is read nil-safe, defaulting to `:idle`.

  The persisted `last_breakdown` snapshot has STRING keys
  (`%{"categories" => [%{"key" => ..., "label" => ..., "tokens" => ...}]}`).
  """
  use MagusWeb, :live_component

  alias Magus.Chat.ContextWindow

  @default_max_context 128_000

  @impl true
  def update(assigns, socket) do
    cw = assigns[:context_window]
    total = field(cw, :last_total_tokens) || 0
    # The selected model's window is the denominator and updates on model change.
    # In auto mode no model is passed, so fall back to the last run's window.
    # Only a positive window is usable: a model with context_window == 0 is truthy
    # in Elixir but would be a /0 denominator, so it falls through to the fallback
    # (mirrors the SPA's `> 0` guard in effectiveContextMax).
    max =
      case model_window(assigns[:model]) do
        mw when is_integer(mw) and mw > 0 -> mw
        _ -> field(cw, :last_max_context) || @default_max_context
      end

    fill = if max > 0, do: min(total / max, 1.0), else: 0.0
    cached = field(cw, :last_cached_tokens)
    cats = categories(cw)
    strategy = field(cw, :strategy)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       total: total,
       max: max,
       fill: fill,
       percent: round(fill * 100),
       color: color_for(fill),
       bar_color: bar_color_for(fill),
       categories: cats,
       rows: rows(cats, total, max),
       cached: cached,
       cached_percent: cached_percent(cached, total),
       strategy: strategy,
       # No per-conversation override → the app default is in effect; surface it
       # so the toggle highlights the active strategy.
       effective_strategy: strategy || ContextWindow.config(:default_strategy),
       strategy_is_default: is_nil(strategy),
       compaction_status: compaction_status(cw),
       # In auto mode no concrete model is selected; attribute the window to the
       # model the last run actually used.
       auto?: is_nil(assigns[:model]),
       model_key: field(cw, :last_model_key),
       # Non-owners (accepted members, workspace grantees) see a read-only donut:
       # the gauge + breakdown render for everyone, but the Clear/Compact/strategy
       # control row is hidden because those actions are owner-only. nil-safe so a
       # caller that omits the assign defaults to read-only.
       is_owner: assigns[:is_owner] == true
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="dropdown dropdown-top"
      data-role="context-donut"
      data-context-fill={Float.round(@fill, 3)}
    >
      <div
        tabindex="0"
        role="button"
        class="btn btn-ghost btn-sm btn-circle"
        title={gettext("Context window")}
      >
        <.donut fill={@fill} color={@color} />
      </div>
      <div
        tabindex="-1"
        class="dropdown-content z-50 bg-base-200 rounded-box shadow-lg p-3 w-72 mt-2"
      >
        <div class="flex items-baseline justify-between gap-2">
          <span class="text-xs font-semibold">{gettext("Context window")}</span>
          <span class="text-xs text-base-content/60 tabular-nums" data-role="context-total">
            {format_tokens(@total)} / {format_tokens(@max)} ({@percent}%)
          </span>
        </div>

        <%!--
          Auto mode has no selected model, so the window size comes from the model
          the last run picked. Attribute it so the denominator is not mysterious.
        --%>
        <p
          :if={@auto? and is_binary(@model_key) and @model_key != ""}
          class="mt-0.5 truncate text-[11px] text-base-content/60"
          data-role="context-model"
          title={@model_key}
        >
          {gettext("via")} {@model_key}
        </p>

        <div class="mt-2 h-1.5 w-full overflow-hidden rounded-full bg-base-300">
          <div class={["h-full rounded-full", @bar_color]} style={"width: #{min(@percent, 100)}%"}>
          </div>
        </div>

        <div
          :if={is_integer(@cached) and @cached > 0}
          class="mt-1.5 text-[11px] text-base-content/60"
          data-role="context-cached"
        >
          {format_tokens(@cached)} {gettext("from cache")}{if @cached_percent,
            do: " (#{@cached_percent}%)"}
        </div>

        <ul class="mt-2.5 space-y-1" data-role="context-breakdown">
          <li :if={@categories == []} class="text-xs text-base-content/60">
            {gettext("No breakdown yet.")}
          </li>
          <li :for={r <- @rows} class="flex items-center gap-2 text-xs">
            <span class={["flex-1 truncate", r.free && "text-base-content/60"]}>{r.label}</span>
            <span class="tabular-nums text-base-content/60">{format_tokens(r.tokens)}</span>
            <span class="w-11 text-right tabular-nums text-base-content/60">{r.percent}%</span>
          </li>
        </ul>

        <%!--
          Controls bubble to ConversationView via plain phx-click (no phx-target):
          non-targeted events from nested live_components reach the owning LiveView.
          One row: strategy toggle (config) on the left, icon actions on the right.
          The effective strategy is highlighted — the app default when there is no
          per-conversation override.

          Owner-only: the underlying Magus.Chat actions are owner-gated, so
          non-owners (accepted members, workspace grantees) see the donut +
          breakdown above read-only and never get this control row.
        --%>
        <div
          :if={@is_owner}
          class="mt-3 pt-3 border-t border-base-300 flex items-center gap-2"
        >
          <% compacting = @compaction_status in [:pending, :running] %>
          <div class="join">
            <button
              type="button"
              data-role="context-strategy-rolling"
              phx-click="set_context_strategy"
              phx-value-strategy="rolling"
              title={
                if @strategy_is_default and @effective_strategy == :rolling,
                  do: gettext("Active by default")
              }
              class={[
                "btn btn-xs join-item",
                @effective_strategy == :rolling && "btn-active btn-primary"
              ]}
            >
              {gettext("Rolling")}
            </button>
            <button
              type="button"
              data-role="context-strategy-compact"
              phx-click="set_context_strategy"
              phx-value-strategy="compact"
              title={
                if @strategy_is_default and @effective_strategy == :compact,
                  do: gettext("Active by default")
              }
              class={[
                "btn btn-xs join-item",
                @effective_strategy == :compact && "btn-active btn-primary"
              ]}
            >
              {gettext("Auto compact")}
            </button>
          </div>

          <div class="flex-1"></div>

          <button
            type="button"
            data-role="context-compact"
            data-compaction-status={@compaction_status}
            phx-click="compact_context"
            disabled={compacting}
            class={["btn btn-xs btn-square", compacting && "btn-disabled opacity-60"]}
            aria-label={
              if @compaction_status == :failed, do: gettext("Retry"), else: gettext("Compact now")
            }
            title={
              cond do
                @compaction_status == :running -> gettext("Compacting...")
                @compaction_status == :pending -> gettext("Compaction queued...")
                @compaction_status == :failed -> gettext("Compaction failed - retry")
                true -> gettext("Summarize older messages to free up the window")
              end
            }
          >
            <span :if={compacting} class="loading loading-spinner loading-xs" />
            <.icon :if={!compacting} name="lucide-combine" class="w-3.5 h-3.5" />
          </button>

          <%!--
            Disabled mid-compaction (same `compacting` flag as the Compact button):
            run_compaction reads the floor, makes a multi-second LLM call, then writes
            summary+pointer. A Clear committed in that window would be silently
            clobbered by the in-flight pass (lost update), so the button is locked.
          --%>
          <button
            type="button"
            data-role="context-clear"
            phx-click="clear_context"
            disabled={compacting}
            title={gettext("Clear")}
            aria-label={gettext("Clear")}
            data-confirm={
              gettext(
                "Clear the live context window? Older messages stay in the transcript but won't be sent to the model."
              )
            }
            class={["btn btn-xs btn-square btn-ghost", compacting && "btn-disabled opacity-60"]}
          >
            <.icon name="lucide-eraser" class="w-3.5 h-3.5" />
          </button>
        </div>

        <a
          href={"/#{Gettext.get_locale()}/docs/conversations/context-window"}
          class="mt-2 block text-[11px] text-base-content/60 hover:text-base-content hover:underline"
        >
          {gettext("Learn about context strategies")}
        </a>
      </div>
    </div>
    """
  end

  attr :fill, :float, required: true
  attr :color, :string, required: true

  defp donut(assigns) do
    ~H"""
    <svg viewBox="0 0 36 36" class="w-3.5 h-3.5">
      <circle
        cx="18"
        cy="18"
        r="15.9155"
        fill="none"
        class="stroke-base-content/40"
        stroke-width="4"
      />
      <circle
        cx="18"
        cy="18"
        r="15.9155"
        fill="none"
        stroke-width="4"
        stroke-linecap="round"
        class={@color}
        stroke-dasharray={"#{Float.round(@fill * 100, 1)} 100"}
        transform="rotate(-90 18 18)"
      />
    </svg>
    """
  end

  defp field(nil, _), do: nil
  defp field(cw, key), do: Map.get(cw, key)

  # Cached-read tokens as a percent of total input tokens, nil-safe. Returns nil
  # unless cached is a positive integer and total is positive, so the panel line
  # is only shown when there is a meaningful cache hit.
  defp cached_percent(cached, total)
       when is_integer(cached) and cached > 0 and is_integer(total) and total > 0,
       do: round(cached / total * 100)

  defp cached_percent(_cached, _total), do: nil

  # Compaction status, nil-safe: a missing window (or missing field) is :idle.
  defp compaction_status(cw), do: field(cw, :compaction_status) || :idle

  defp model_window(%{context_window: w}), do: w
  defp model_window(_), do: nil

  defp color_for(f) do
    cond do
      f >= ContextWindow.config(:alert_fraction) -> "stroke-error"
      f >= ContextWindow.config(:warn_fraction) -> "stroke-warning"
      true -> "stroke-success"
    end
  end

  defp categories(cw) do
    case field(cw, :last_breakdown) do
      %{"categories" => cats} when is_list(cats) ->
        Enum.map(cats, fn c -> %{label: c["label"], tokens: c["tokens"]} end)

      _ ->
        []
    end
  end

  # Fill-bar background by band (mirrors `color_for/1`, which returns stroke-*).
  defp bar_color_for(f) do
    cond do
      f >= ContextWindow.config(:alert_fraction) -> "bg-error"
      f >= ContextWindow.config(:warn_fraction) -> "bg-warning"
      true -> "bg-success"
    end
  end

  # Breakdown rows with each category's share of the window plus a trailing
  # "Free space" row (max - total), mirroring the SPA panel.
  defp rows(categories, total, max) when is_integer(max) and max > 0 do
    cats =
      categories
      |> Enum.map(fn c ->
        %{label: c.label, tokens: c.tokens, percent: pct(c.tokens, max), free: false}
      end)
      # Largest categories first; the "Free space" remainder always sits last.
      |> Enum.sort_by(& &1.tokens, :desc)

    free = Kernel.max(max - total, 0)
    cats ++ [%{label: gettext("Free space"), tokens: free, percent: pct(free, max), free: true}]
  end

  defp rows(categories, _total, _max) do
    categories
    |> Enum.map(&Map.merge(&1, %{percent: 0.0, free: false}))
    |> Enum.sort_by(& &1.tokens, :desc)
  end

  defp pct(tokens, max) when is_integer(tokens) and is_integer(max) and max > 0,
    do: Float.round(tokens / max * 100, 1)

  defp pct(_tokens, _max), do: 0.0

  # Compact token count: "921.7K" / "1.0M" (mirrors the SPA `formatTokens`).
  defp format_tokens(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  defp format_tokens(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_tokens(n) when is_integer(n), do: Integer.to_string(n)
  defp format_tokens(_n), do: "0"
end
