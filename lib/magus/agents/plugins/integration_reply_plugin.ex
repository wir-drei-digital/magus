defmodule Magus.Agents.Plugins.IntegrationReplyPlugin do
  @moduledoc """
  Plugin that handles integration-side feedback during agent processing.

  Two responsibilities:

  1. **Typing indicators** — sends provider-specific "typing" actions during
     streaming and tool execution so the external user sees activity feedback.
     Throttled to one call per `@typing_interval_ms` to avoid API spam.

  2. **Reply dispatch** — sends the final response text (and attachments) back
     through the integration provider via `ReplyDispatcher`.

  | Signal                 | Action                                              |
  |------------------------|-----------------------------------------------------|
  | `ai.request.started`   | Look up integration, cache, send initial typing     |
  | `ai.llm.delta`         | Re-send typing indicator (throttled)                |
  | `ai.tool.started`      | Re-send typing indicator (throttled)                |
  | `ai.request.completed` | Dispatch reply text to integration if linked         |
  """

  use Jido.Plugin,
    name: "integration_reply",
    state_key: :integration_reply,
    actions: [],
    description: "Typing indicators and reply dispatch for integration providers",
    category: "magus",
    tags: ["conversation", "integration", "reply", "typing"],
    signal_patterns: [
      "ai.request.started",
      "ai.llm.delta",
      "ai.tool.started",
      "ai.request.completed"
    ]

  require Logger

  alias Magus.Agents.Plugins.Support.Helpers
  alias Magus.Integrations
  alias Magus.Integrations.ReplyDispatcher

  # Telegram typing indicator lasts ~5s; re-send every 4s to keep it alive
  @typing_interval_ms 4_000

  @impl Jido.Plugin
  def mount(_agent, config) do
    {:ok, %{config: config}}
  end

  @impl Jido.Plugin
  def handle_signal(%{type: "ai.request.started"}, context) do
    agent = context[:agent]
    conversation_id = Helpers.get_conversation_id(agent)

    # Look up and cache integration info for this request
    case resolve_integration_info(conversation_id) do
      {:ok, info} ->
        cache_integration_info(info)
        send_typing(info)
        Process.put(:integration_reply_typing_last_sent, System.monotonic_time(:millisecond))

      :not_integration ->
        cache_integration_info(:none)
    end

    {:ok, :continue}
  end

  def handle_signal(%{type: "ai.llm.delta"}, _context) do
    maybe_send_throttled_typing()
    {:ok, :continue}
  end

  def handle_signal(%{type: "ai.tool.started"}, _context) do
    maybe_send_throttled_typing()
    {:ok, :continue}
  end

  def handle_signal(%{type: "ai.request.completed"} = signal, context) do
    agent = context[:agent]
    conversation_id = Helpers.get_conversation_id(agent)
    data = signal.data || %{}
    request_id = data[:request_id] || data["request_id"]

    if conversation_id && request_id do
      dispatch_reply(conversation_id, request_id, signal, agent)
    end

    # Clean up process dict
    clear_integration_cache()

    {:ok, :continue}
  end

  def handle_signal(_signal, _context), do: {:ok, :continue}

  # ============================================================================
  # Typing Indicators
  # ============================================================================

  defp maybe_send_throttled_typing do
    case get_cached_integration_info() do
      :none ->
        :ok

      nil ->
        # Not resolved yet (shouldn't happen, but safe)
        :ok

      info ->
        now = System.monotonic_time(:millisecond)
        last_sent = Process.get(:integration_reply_typing_last_sent, 0)

        if now - last_sent >= @typing_interval_ms do
          send_typing(info)
          Process.put(:integration_reply_typing_last_sent, now)
        end
    end
  end

  defp send_typing(%{recipient_id: nil}), do: :ok

  defp send_typing(%{user_id: user_id, provider_key: provider_key, recipient_id: recipient_id}) do
    Task.Supervisor.start_child(Integrations.WebhookTaskSupervisor, fn ->
      inputs = %{
        user_id: user_id,
        provider_key: provider_key,
        operation: :send_chat_action,
        params: %{recipient_id: recipient_id, action: "typing"}
      }

      case Reactor.run(Integrations.Reactors.RunIntegration, inputs, async?: false) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.debug("Typing indicator failed: #{inspect(reason)}")
      end
    end)
  end

  # ============================================================================
  # Reply Dispatch
  # ============================================================================

  defp dispatch_reply(conversation_id, request_id, signal, agent) do
    response_text = extract_response_text(signal, agent)

    if response_text != "" do
      case fetch_response_attachments(request_id, agent) do
        attachments when is_list(attachments) and attachments != [] ->
          ReplyDispatcher.maybe_dispatch_with_attachments(
            conversation_id,
            response_text,
            attachments,
            request_id
          )

        _ ->
          ReplyDispatcher.maybe_dispatch(conversation_id, response_text, request_id)
      end

      # Signal to ActivityLogPlugin that an integration reply was dispatched
      case get_cached_integration_info() do
        %{provider_key: provider_key} when is_binary(provider_key) ->
          Process.put(:activity_log_integration_reply, %{
            provider: provider_key,
            conversation_id: conversation_id
          })

        _ ->
          :ok
      end
    end
  end

  defp extract_response_text(signal, agent) do
    strategy_state = Helpers.get_strategy_state(agent)
    data = signal.data || %{}

    Helpers.first_non_blank([
      strategy_state[:streaming_text],
      data[:result],
      data["result"],
      ""
    ])
  end

  defp fetch_response_attachments(request_id, agent) do
    strategy_state = Helpers.get_strategy_state(agent)
    iteration = strategy_state[:iteration]

    message_id =
      if is_integer(iteration) and iteration > 0 do
        Helpers.response_id_for_turn(request_id, iteration)
      else
        Helpers.response_id_for_request(request_id)
      end

    case Magus.Chat.get_message(message_id, authorize?: false) do
      {:ok, message} -> message.attachments || []
      {:error, _} -> []
    end
  end

  # ============================================================================
  # Integration Info Resolution & Cache
  # ============================================================================

  defp resolve_integration_info(conversation_id) do
    with {:ok, mapping} <-
           Integrations.get_integration_conversation_by_conversation_id(
             conversation_id,
             authorize?: false
           ) do
      {:ok,
       %{
         user_id: mapping.user_integration.user_id,
         provider_key: mapping.user_integration.provider_key,
         recipient_id: mapping.external_identifier
       }}
    else
      {:error, _} ->
        # Try single-mode fallback
        resolve_single_mode_integration(conversation_id)
    end
  end

  defp resolve_single_mode_integration(conversation_id) do
    case Integrations.get_integration_by_conversation(conversation_id, authorize?: false) do
      {:ok, integration} ->
        # Single-mode doesn't have an external_identifier mapping,
        # so we can't determine the recipient for typing indicators
        case integration.conversation_id do
          ^conversation_id ->
            {:ok,
             %{
               user_id: integration.user_id,
               provider_key: integration.provider_key,
               recipient_id: nil
             }}

          _ ->
            :not_integration
        end

      {:error, _} ->
        :not_integration
    end
  end

  # Process dict cache for integration info during a request
  defp cache_integration_info(info) do
    Process.put(:integration_reply_info, info)
    Process.put(:integration_reply_typing_last_sent, 0)
  end

  defp get_cached_integration_info do
    Process.get(:integration_reply_info)
  end

  defp clear_integration_cache do
    Process.delete(:integration_reply_info)
    Process.delete(:integration_reply_typing_last_sent)
  end
end
