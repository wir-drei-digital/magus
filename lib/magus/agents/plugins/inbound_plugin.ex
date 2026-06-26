defmodule Magus.Agents.Plugins.InboundPlugin do
  @moduledoc """
  Plugin that handles inbound signal transformation for conversation agents.

  Transforms incoming user signals before they reach the ReAct strategy:

  | Incoming Signal      | Transformation                                                    |
  |----------------------|-------------------------------------------------------------------|
  | `message.user`       | Pre-flight (model resolution, limits, context) via Preflight      |
  |                      | OR media bypass for image/video modes via MediaBypass             |
  | `message.cancel`     | Rewrite to `ai.react.cancel`                                     |
  | `message.steer`      | Promote queued steering; inject `ai.react.steer` or redispatch    |
  | `ai.request.error`   | PubSub error broadcast (busy rejection, etc.)                     |

  This is one of several focused plugins extracted from the monolithic conversation skill.
  It handles ONLY inbound signal transformation -- no streaming, no persistence, no tool events.

  ## Support Modules

  - `Helpers` -- state extraction and formatting utilities
  - `Preflight` -- usage limit validation and ReAct signal building
  - `MediaBypass` -- image/video generation dispatch
  """

  use Jido.Plugin,
    name: "inbound",
    state_key: :inbound,
    actions: [],
    description: "Inbound signal transformation for conversation agents",
    category: "magus",
    tags: ["conversation", "inbound", "signal-transformation"],
    signal_patterns: [
      "message.user",
      "message.cancel",
      "message.steer",
      "agent.resume",
      "ai.request.error"
    ]

  require Logger

  alias Magus.Agents.Plugins.Support.{ErrorMessages, Helpers, MediaBypass, Preflight}
  alias Magus.Agents.Signals
  alias Magus.Agents.Steering

  # ============================================================================
  # Plugin Callbacks
  # ============================================================================

  @impl Jido.Plugin
  def mount(_agent, config) do
    {:ok, %{config: config}}
  end

  @impl Jido.Plugin
  def handle_signal(signal, context) do
    agent = context[:agent]

    case signal.type do
      "message.user" ->
        handle_message_user(signal, agent)

      "message.cancel" ->
        handle_message_cancel()

      "message.steer" ->
        handle_message_steer(agent)

      "agent.resume" ->
        handle_agent_resume(signal, agent)

      "ai.request.error" ->
        conversation_id = Helpers.get_conversation_id(agent)
        handle_request_error(signal, conversation_id, agent)

      _ ->
        Logger.debug("[InboundPlugin] Unhandled signal: #{signal.type}")
        {:ok, :continue}
    end
  end

  # ============================================================================
  # Inbound Signal Handlers
  # ============================================================================

  defp handle_message_user(signal, agent) do
    state = agent.state || %{}
    mode = Helpers.get_mode(state, signal)

    if mode in [:image_generation, :video_generation] do
      MediaBypass.handle(signal, agent, mode)
    else
      Preflight.build_react_signal(signal, agent, mode)
    end
  end

  defp handle_agent_resume(signal, agent) do
    Preflight.build_resume_react_signal(signal, agent)
  end

  defp handle_message_cancel do
    cancel_signal = Jido.Signal.new!("ai.react.cancel", %{reason: :user_cancelled})
    {:ok, {:continue, cancel_signal}}
  end

  # Decision point for mid-turn steering. Promotes any queued steering messages,
  # then either injects them into the active run (via `ai.react.steer`) or, when
  # the run is already idle (race fallback), redispatches them as a fresh turn.
  defp handle_message_steer(agent) do
    conversation_id = Helpers.get_conversation_id(agent)
    active_request_id = Helpers.get_active_request_id(agent)
    promoted = Steering.promote_queued(conversation_id)

    case build_steer_outcome(promoted, active_request_id, conversation_id) do
      {:emit, signal} ->
        {:ok, {:continue, signal}}

      {:redispatch, conv_id, newest_id} ->
        Task.Supervisor.start_child(Magus.AgentLoopTaskSupervisor, fn ->
          Steering.redispatch(conv_id, newest_id)
        end)

        {:ok, :continue}

      :noop ->
        {:ok, :continue}
    end
  end

  @doc false
  def build_steer_outcome([], _active_request_id, _conversation_id), do: :noop

  def build_steer_outcome(promoted, active_request_id, conversation_id)
      when is_list(promoted) do
    newest = List.last(promoted)
    texts = Enum.map(promoted, & &1.text)

    if is_binary(active_request_id) do
      signal =
        Jido.Signal.new!("ai.react.steer", %{
          texts: texts,
          newest_id: newest.id,
          conversation_id: conversation_id
        })

      {:emit, signal}
    else
      {:redispatch, conversation_id, newest.id}
    end
  end

  defp handle_request_error(signal, conversation_id, agent) do
    data = signal.data || %{}
    reason = data[:reason] || data["reason"]
    message = data[:message] || data["message"] || "Request rejected"
    request_id = data[:request_id] || data["request_id"]

    message_id =
      Helpers.get_current_message_id(agent) ||
        if(request_id, do: Helpers.response_id_for_request(request_id))

    Logger.warning("Request error for conversation #{conversation_id}: #{reason} - #{message}")
    Signals.error(conversation_id, message_id, reason, message)

    ErrorMessages.create_error_event(conversation_id, reason, message)

    Signals.state_change(conversation_id, :idle)

    Signals.response_complete(conversation_id, %{
      triggering_message_id: request_id || Helpers.get_parent_message_id(agent)
    })

    {:ok, :continue}
  end
end
