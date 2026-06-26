defmodule Magus.Agents.Plugins.ContextPlugin do
  @moduledoc """
  Persists the per-turn context-window snapshot from `ai.context` and reconciles
  the real input/cached token totals from `ai.usage`, then broadcasts
  `context.updated`. Best-effort: failures are logged and never disrupt the
  signal pipeline. Mirrors `UsagePlugin`.

  ## Signals Handled

  | Signal       | Action                                                          |
  |--------------|-----------------------------------------------------------------|
  | `ai.context` | Upsert the snapshot (breakdown/total/model/max) + broadcast     |
  | `ai.usage`   | Patch the real input/cached token totals + re-broadcast         |
  """

  use Jido.Plugin,
    name: "context",
    state_key: :context,
    actions: [],
    description: "Records context-window snapshots from ai.context / ai.usage",
    category: "magus",
    tags: ["conversation", "context"],
    signal_patterns: ["ai.context", "ai.usage"]

  require Logger

  alias Magus.Agents.Plugins.Support.Helpers
  alias Magus.Agents.Signals
  alias Magus.Agents.Support.AiAgent
  alias Magus.Chat.ContextWindow

  # ============================================================================
  # Plugin Callbacks
  # ============================================================================

  @impl Jido.Plugin
  def mount(_agent, config) do
    {:ok, %{config: config}}
  end

  @impl Jido.Plugin
  def handle_signal(%{type: "ai.context"} = signal, context) do
    agent = context[:agent]
    conv_id = Helpers.get_conversation_id(agent)
    data = signal.data || %{}
    breakdown = data[:breakdown] || data["breakdown"] || %{}

    {:ok, _} =
      Magus.Chat.upsert_context_snapshot(
        %{
          conversation_id: conv_id,
          last_breakdown: stringify(breakdown),
          last_total_tokens: breakdown[:total_tokens] || breakdown["total_tokens"],
          last_model_key: data[:model_key] || data["model_key"],
          last_max_context: data[:max_context] || data["max_context"]
        },
        actor: %AiAgent{}
      )

    Signals.context_updated(conv_id, breakdown)
    maybe_auto_compact(conv_id, breakdown)
    {:ok, :continue}
  rescue
    e ->
      Logger.warning("ContextPlugin ai.context failed: #{Exception.message(e)}")
      {:ok, :continue}
  end

  def handle_signal(%{type: "ai.usage"} = signal, context) do
    agent = context[:agent]
    conv_id = Helpers.get_conversation_id(agent)
    data = signal.data || %{}
    input = data[:input_tokens] || data["input_tokens"]
    # cached now arrives in metadata.cached_tokens (forwarded by ReactStrategy,
    # since the Usage signal schema only allows input/output/total/metadata). The
    # top-level fallback is kept for safety. input_tokens is the critical field
    # and arrives top-level.
    metadata = data[:metadata] || data["metadata"] || %{}

    cached =
      metadata[:cached_tokens] || metadata["cached_tokens"] ||
        data[:cached_tokens] || data["cached_tokens"]

    if conv_id && input do
      case Magus.Chat.get_context_window(conv_id, actor: %AiAgent{}) do
        {:ok, cw} ->
          {:ok, _} =
            Magus.Chat.patch_context_usage(
              cw,
              %{
                last_actual_input_tokens: input,
                last_cached_tokens: cached
              },
              actor: %AiAgent{}
            )

          Signals.context_updated(conv_id, %{
            last_actual_input_tokens: input,
            last_cached_tokens: cached
          })

        _ ->
          :noop
      end
    end

    {:ok, :continue}
  rescue
    e ->
      Logger.warning("ContextPlugin ai.usage failed: #{Exception.message(e)}")
      {:ok, :continue}
  end

  def handle_signal(_signal, _context), do: {:ok, :continue}

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp stringify(map) when is_map(map), do: Jason.decode!(Jason.encode!(map))
  defp stringify(other), do: other

  # ---------------------------------------------------------------------------
  # Auto-compact valve
  # ---------------------------------------------------------------------------

  # Auto-request compaction when a `:compact`-strategy window crosses the
  # high-water fill threshold. The `:rolling` strategy self-bounds at read time
  # (BuildMessageHistory trims), so it never auto-compacts here.
  #
  # Best-effort: always returns :ok. It runs after the snapshot/broadcast have
  # already happened, so any failure here must not propagate. The caller ignores
  # the return value.
  defp maybe_auto_compact(conv_id, breakdown) do
    with true <- ContextWindow.config(:auto_compact_enabled),
         {:ok, fill} when fill >= 0 <- compute_fill(breakdown),
         true <- fill >= ContextWindow.config(:auto_compact_fraction),
         {:ok, cw} when not is_nil(cw) <-
           Magus.Chat.get_context_window(conv_id, actor: %AiAgent{}),
         :compact <-
           ContextWindow.resolve_strategy(%{
             strategy: cw.strategy,
             user_default: ContextWindow.user_default_strategy(conv_id)
           }),
         :idle <- cw.compaction_status do
      case Magus.Chat.request_context_compaction(cw, actor: %AiAgent{}) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("ContextPlugin auto-compact request failed: #{inspect(reason)}")
          :ok
      end
    else
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning("ContextPlugin auto-compact failed: #{Exception.message(e)}")
      :ok
  end

  # fill = total_tokens / max_context, guarding max_context > 0. Returns
  # {:ok, fill} or :error when either field is missing/non-positive. Handles
  # both atom and string keys (mirrors the ai.context handler reads).
  defp compute_fill(breakdown) do
    total = breakdown[:total_tokens] || breakdown["total_tokens"]
    max = breakdown[:max_context] || breakdown["max_context"]

    if is_number(total) && is_number(max) && max > 0 do
      {:ok, total / max}
    else
      :error
    end
  end
end
