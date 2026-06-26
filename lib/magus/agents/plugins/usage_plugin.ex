defmodule Magus.Agents.Plugins.UsagePlugin do
  @moduledoc """
  Plugin that records LLM token usage from `ai.usage` signals.

  This is the simplest of the conversation plugins -- it handles exactly one
  signal type (`ai.usage`) and delegates to `UsageRecorder.record!/1` for
  actual persistence.

  Recording is best-effort: failures are logged as warnings but never disrupt
  the signal pipeline.

  ## Signal Handled

  | Signal       | Action                                       |
  |--------------|----------------------------------------------|
  | `ai.usage`   | Persist token usage via `UsageRecorder`      |
  """

  use Jido.Plugin,
    name: "usage",
    state_key: :usage,
    actions: [],
    description: "Records LLM token usage from ai.usage signals",
    category: "magus",
    tags: ["conversation", "usage", "billing"],
    signal_patterns: ["ai.usage"]

  require Logger

  alias Magus.Agents.Plugins.Support.Helpers
  alias Magus.Agents.Persistence.UsageRecorder

  # ============================================================================
  # Plugin Callbacks
  # ============================================================================

  @impl Jido.Plugin
  def mount(_agent, config) do
    {:ok, %{config: config}}
  end

  @impl Jido.Plugin
  def handle_signal(%{type: "ai.usage"} = signal, context) do
    agent = context[:agent]
    handle_usage(signal, agent)
  end

  def handle_signal(_signal, _context), do: {:ok, :continue}

  # ============================================================================
  # Usage Recording
  # ============================================================================

  defp handle_usage(signal, agent) do
    data = signal.data || %{}
    state = agent.state || %{}
    call_id = data[:call_id] || data["call_id"]
    request_id = Helpers.resolve_request_id(data, call_id)
    iteration = Helpers.resolve_iteration(data, call_id)

    message_id = resolve_usage_message_id(data, agent, request_id, iteration)

    if is_nil(message_id) do
      Logger.warning(
        "ai.usage signal without request_id (no active_request_id or call_id), usage won't be attributed to a message"
      )
    end

    model_key = data[:model] || data["model"]
    provider = data[:provider] || data["provider"]
    input_tokens = data[:input_tokens] || data["input_tokens"] || 0
    output_tokens = data[:output_tokens] || data["output_tokens"] || 0
    generation_id = usage_generation_id(data)

    mode = state[:mode] || :chat
    usage_type = UsageRecorder.usage_type_for_mode(mode)

    UsageRecorder.record!(
      # Bill the member who sent the triggering message, not the conversation
      # owner (magus-k3at); falls back to the owner for autonomous turns.
      user_id: Helpers.acting_user_id(agent, request_id),
      message_id: message_id,
      conversation_id: Helpers.get_conversation_id(agent),
      model_key: model_key,
      provider: provider,
      provider_generation_id: generation_id,
      usage: %{
        "prompt_tokens" => input_tokens,
        "completion_tokens" => output_tokens
      },
      usage_type: usage_type
    )

    {:ok, :continue}
  rescue
    e ->
      Logger.warning("UsagePlugin: failed to record usage: #{Exception.message(e)}")
      {:ok, :continue}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp usage_generation_id(data) do
    metadata = data[:metadata] || data["metadata"] || %{}
    metadata[:generation_id] || metadata["generation_id"]
  end

  defp resolve_usage_message_id(data, agent, request_id, iteration) do
    explicit = data[:message_id] || data["message_id"]

    cond do
      Helpers.valid_message_id?(explicit) ->
        explicit

      Helpers.valid_message_id?(request_id) and is_integer(iteration) and iteration > 0 ->
        Helpers.response_id_for_turn(request_id, iteration)

      Helpers.valid_message_id?(request_id) ->
        Helpers.response_id_for_request(request_id)

      true ->
        Helpers.get_current_message_id(agent)
    end
  end
end
