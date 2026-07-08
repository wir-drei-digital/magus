defmodule Magus.Agents.ConversationAgent do
  @moduledoc """
  Jido Agent for handling conversation message processing and LLM interaction.

  Uses the Magus ReAct reasoning strategy with composable plugins for signal
  translation between the ReAct signal world and Magus's PubSub/persistence world.

  ## Architecture

  - **Strategy**: `Magus.Agents.Strategies.ReactStrategy` handles the agentic loop
    (LLM streaming, tool calling, iteration control)
  - **Plugins**: Six composable plugins handle signal translation:
    - `InboundPlugin` — transforms `message.user` → `ai.react.query` (with pre-flight checks),
      handles `message.cancel` → `ai.react.cancel`, bypasses ReAct for media generation modes
    - `StreamingPlugin` — translates ReAct LLM signals (`ai.llm.delta`, etc.) → PubSub broadcasts
    - `PersistencePlugin` — persists completed responses and tool results to the database
    - `ToolEventPlugin` — translates ReAct tool signals (`ai.tool.*`) → PubSub broadcasts
    - `UsagePlugin` — tracks token usage and costs
    - `AgentRunCompletionPlugin` — marks AgentRun records as complete/failed when target conversations finish

  ## Lifecycle

  The agent is created per conversation with ID pattern: `conv:<conversation_uuid>`

  1. **Signal Reception**: User messages trigger `message.user` signals
  2. **Plugin Interception**: InboundPlugin transforms to `ai.react.query`
  3. **ReAct Loop**: Strategy handles LLM calls, tool execution, iteration
  4. **Signal Translation**: Plugins translate ReAct events to PubSub broadcasts
  5. **Hibernation**: After 5 minutes idle, process exits with state saved to DB
  6. **Recovery**: On next message, state is restored from DB (thaw)

  ## State Structure

  ```elixir
  %{
    conversation_id: "uuid",
    user_id: "uuid",
    model_keys: %{chat: "openrouter:model-name", image: "...", video: "..."},
    mode: :chat | :search | :reasoning | :image_generation | :video_generation
  }
  ```
  """

  @default_system_prompt """
  You are a helpful AI assistant.
  When you need to perform an action, use the available tools.
  When you have enough information to answer, provide your final answer directly.
  Do not include your internal reasoning or thought process in your response.
  """

  # Runtime tools are assembled per-turn by Magus.Agents.Tools.ToolBuilder and
  # passed to the strategy via Preflight; any static tools listed here would be
  # overridden by that per-turn list. The empty list satisfies the strategy's
  # init-time `:tools` requirement without claiming a static toolset.
  use Jido.Agent,
    name: "conversation",
    strategy:
      {Magus.Agents.Strategies.ReactStrategy,
       [
         tools: [],
         streaming: true,
         system_prompt: @default_system_prompt,
         llm_opts: %{
           max_tokens: 100_000,
           temperature: 0.8
         },
         tool_timeout_ms: 120_000,
         tool_max_retries: 1,
         runtime_task_supervisor: Magus.Agents.RunnerTaskSupervisor,
         observability: %{
           emit_signals?: true,
           emit_lifecycle_signals?: true,
           emit_llm_deltas?: true
         }
       ]},
    plugins: [
      # InboxEventPlugin MUST be before InboundPlugin — InboundPlugin transforms
      # message.user → ai.react.query, and InboxEventPlugin needs to see message.user
      # for mention detection and approval response matching.
      Magus.Agents.Plugins.InboxEventPlugin,
      Magus.Agents.Plugins.InboundPlugin,
      Magus.Agents.Plugins.StreamingPlugin,
      Magus.Agents.Plugins.PersistencePlugin,
      Magus.Agents.Plugins.ToolEventPlugin,
      Magus.Agents.Plugins.UsagePlugin,
      Magus.Agents.Plugins.ContextPlugin,
      Magus.Agents.Plugins.AgentRunCompletionPlugin,
      Magus.Agents.Plugins.IntegrationReplyPlugin,
      Magus.Agents.Plugins.ActivityLogPlugin
    ],
    schema: [
      conversation_id: [
        type: :string,
        required: true,
        doc: "UUID of the conversation"
      ],
      user_id: [
        type: :string,
        required: true,
        doc: "UUID of the conversation owner"
      ],
      model_keys: [
        type: {:map, :atom, :string},
        default: %{},
        doc: "Model keys per mode: %{chat: \"...\", image: \"...\", video: \"...\"}"
      ],
      mode: [
        type: :atom,
        default: :chat,
        constraints: [one_of: [:chat, :search, :reasoning, :image_generation, :video_generation]],
        doc: "Chat mode for this conversation"
      ],
      model: [
        type: :any,
        default: :fast,
        doc:
          "Resolved model key string (e.g., openrouter:anthropic/claude-sonnet-4) or atom alias"
      ]
    ]

  alias Magus.Agents.Persistence.Checkpoint, as: Persistence
  alias Magus.Agents.Plugins.Support.Helpers

  require Logger

  # Signal routing is handled by the ReAct Strategy via signal_routes/1
  # The strategy defines routes for "ai.react.query", "ai.react.cancel", etc.
  # InboundPlugin transforms "message.user" → "ai.react.query"
  # and "message.cancel" → "ai.react.cancel" before they reach the router.

  @doc """
  Serialize agent state for persistence during hibernation.

  Called by Jido.Persist before the agent process terminates.
  Returns the canonical checkpoint format with domain state nested under `:state`.
  """
  def checkpoint(agent, _ctx) do
    state = agent.state || %{}

    # Get model_keys, handling both new format and legacy model_key
    model_keys =
      case Persistence.get_value(state, :model_keys) do
        keys when is_map(keys) and map_size(keys) > 0 ->
          # Convert atom keys to strings for JSON serialization
          Map.new(keys, fn {k, v} -> {to_string(k), v} end)

        _ ->
          # Legacy fallback: convert single model_key to chat key
          legacy_key = Persistence.get_value(state, :model_key)
          if legacy_key, do: %{"chat" => legacy_key}, else: %{}
      end

    strategy_state = state[:__strategy__] || %{}
    conversation_id = Persistence.get_value(state, :conversation_id)
    was_active = strategy_state[:status] in [:awaiting_llm, :awaiting_tool]

    if was_active do
      settle_interrupted_turn(conversation_id, strategy_state[:active_request_id])
    end

    Persistence.wrap_checkpoint(__MODULE__, agent.id, %{
      conversation_id: conversation_id,
      user_id: Persistence.get_value(state, :user_id),
      model_keys: model_keys,
      mode: Persistence.get_value(state, :mode) || :chat,
      was_active: was_active,
      active_message_id: strategy_state[:active_request_id]
    })
  end

  # Checkpointing an ACTIVE turn means the agent is stopping mid-turn (deploy
  # drain or crash; idle-timeout hibernation is blocked by the run's
  # attachment). Settle the conversation immediately: broadcast idle so the UI
  # drops its thinking state and error-mark the stuck streaming rows, instead
  # of leaving both until the next thaw's recovery pass. Best effort — a
  # checkpoint must never fail because of these side effects.
  defp settle_interrupted_turn(conversation_id, active_request_id)
       when is_binary(conversation_id) do
    Logger.warning(
      "ConversationAgent conv:#{conversation_id} checkpointed mid-turn " <>
        "(request #{inspect(active_request_id)}); settling interrupted turn"
    )

    Magus.Agents.Signals.state_change(conversation_id, :idle)
    Magus.Agents.Recovery.sweep_streaming_messages(conversation_id)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp settle_interrupted_turn(_conversation_id, _active_request_id), do: :ok

  @doc """
  Restore agent state from persistence after hibernation (thaw).

  Called by Jido.Persist when recovering a hibernated agent.
  Receives the checkpoint data (plain map) and reconstructs the agent.
  """
  def restore(data, _ctx) when is_map(data) and not is_struct(data) do
    Logger.debug("ConversationAgent.restore: Received checkpoint data: #{inspect(data)}")

    state_data = Persistence.extract_state(data)
    id = Persistence.get_value(data, :id)

    case Persistence.validate_required(data, state_data,
           data: :id,
           state: :conversation_id,
           state: :user_id
         ) do
      {:error, {:missing_field, field}} ->
        Logger.error("ConversationAgent.restore: Missing required field '#{field}'")
        {:error, {:missing_field, field}}

      :ok ->
        conversation_id = Persistence.get_value(state_data, :conversation_id)
        user_id = Persistence.get_value(state_data, :user_id)
        mode = normalize_mode(Persistence.get_value(state_data, :mode) || :chat)

        # Get model_keys, handling both new format and legacy model_key
        model_keys =
          case Persistence.get_value(state_data, :model_keys) do
            keys when is_map(keys) and map_size(keys) > 0 ->
              Helpers.normalize_model_keys(keys)

            _ ->
              legacy_key = Persistence.get_value(state_data, :model_key)
              if legacy_key, do: %{chat: legacy_key}, else: %{}
          end

        # Derive the primary model key for the strategy config
        model = model_keys[:chat]

        agent = new(id: id)

        was_active =
          Persistence.get_value(state_data, :was_active) ||
            Persistence.get_value(state_data, "was_active") ||
            false

        active_message_id =
          Persistence.get_value(state_data, :active_message_id) ||
            Persistence.get_value(state_data, "active_message_id")

        base_state = %{
          conversation_id: conversation_id,
          user_id: user_id,
          model_keys: model_keys,
          mode: mode,
          model: model
        }

        state =
          if was_active do
            Map.put(base_state, :__recovery__, %{
              was_active: true,
              active_message_id: active_message_id
            })
          else
            base_state
          end

        set(agent, state)
    end
  end

  # Fallback for any other data type
  def restore(data, _ctx) do
    Logger.error("ConversationAgent.restore: Received unexpected data type: #{inspect(data)}")
    {:error, {:invalid_agent_data, data}}
  end

  # Normalize mode to atom (may come as string from JSON serialization)
  defp normalize_mode(mode) when is_atom(mode), do: mode

  defp normalize_mode(mode) when is_binary(mode) do
    String.to_existing_atom(mode)
  rescue
    ArgumentError -> :chat
  end

  defp normalize_mode(_), do: :chat
end
