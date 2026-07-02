defmodule Magus.Agents.Plugins.Support.MediaBypass do
  @moduledoc false
  # Handles image/video generation requests by bypassing ReAct and routing
  # directly to MediaGenerator.

  require Logger

  alias Magus.Agents.Context.ConversationState, as: State
  alias Magus.Agents.Support.MediaGenerator
  alias Magus.Agents.Plugins.Support.{Helpers, Preflight}
  alias Magus.Models.{Resolution, Resolver}
  alias Magus.Agents.Signals
  alias Magus.Chat

  @doc """
  Handle a media generation request. Resolves the model, checks limits,
  builds a ConversationState, and dispatches to MediaGenerator.

  Returns `{:ok, {:override, Noop}}` to halt signal propagation.
  """
  def handle(signal, agent, mode) do
    data = signal.data || %{}
    conversation_id = Helpers.get_conversation_id(agent)

    Logger.info("Media generation bypass for conversation #{conversation_id}, mode: #{mode}")

    state = agent.state || %{}

    model_keys =
      Helpers.normalize_model_keys(data[:model_keys] || data["model_keys"] || state[:model_keys])

    selected_model_id = data[:selected_model_id] || data["selected_model_id"]

    # Scope owned-model visibility to the agent owner. Owned media models are
    # blocked in 2b-1, so this is consistency with the other call sites rather
    # than a leak vector.
    {:ok, resolution} =
      Resolver.resolve(state[:user_id], %{
        model_keys: model_keys,
        mode: mode,
        selected_model_id: selected_model_id
      })

    model = resolution.model
    user = Preflight.load_user_for_limits(state[:user_id])
    message_id = data[:message_id] || data["message_id"]

    # Hard-stop (phase 2b-2b): a broken EXPLICIT media selection blocks the turn
    # before any generation call, on the same error/event rails as the text path.
    if Resolution.degraded?(resolution) do
      conversation = load_conversation_for_scope(conversation_id)

      Preflight.handle_broken_selection(
        conversation_id,
        message_id,
        resolution,
        Preflight.broken_selection_scope(resolution, conversation, mode)
      )

      Signals.state_change(conversation_id, :idle)
      Signals.response_complete(conversation_id, %{})
      {:ok, {:override, Jido.Actions.Control.Noop}}
    else
      dispatch_after_limit_check(
        agent,
        mode,
        conversation_id,
        state,
        data,
        model,
        model_keys,
        user,
        message_id
      )
    end
  end

  defp dispatch_after_limit_check(
         agent,
         mode,
         conversation_id,
         state,
         data,
         model,
         model_keys,
         user,
         message_id
       ) do
    case Preflight.check_usage_limit(user, mode, model, nil) do
      {:ok, :allowed} ->
        text = data[:text] || data["text"] || ""

        media_state = %State{
          conversation_id: conversation_id,
          user_id: state[:user_id],
          mode: mode,
          model_keys: model_keys,
          model_record: model,
          current_message_id: message_id || Ash.UUID.generate(),
          parent_message_id: message_id,
          accumulated_text: text,
          llm_context: build_media_llm_context(conversation_id, message_id, text),
          pending_tool_calls: [],
          custom_agent_id: state[:custom_agent_id]
        }

        dispatch_media_generation(agent, media_state, mode, conversation_id)
        {:ok, {:override, Jido.Actions.Control.Noop}}

      {:error, error} ->
        Preflight.handle_limit_exceeded(conversation_id, message_id, error)
        {:ok, {:override, Jido.Actions.Control.Noop}}
    end
  end

  # --- Private ---

  # Load only what `broken_selection_scope/3` needs to distinguish a
  # conversation-set media pin from a user default. Returns nil on any failure;
  # the scope helper then treats a key-based ask as user-scoped.
  defp load_conversation_for_scope(conversation_id) do
    case Chat.get_conversation(conversation_id,
           load: [
             :selected_image_model,
             :selected_video_model,
             custom_agent: [:image_model, :video_model]
           ],
           authorize?: false
         ) do
      {:ok, conversation} -> conversation
      _ -> nil
    end
  end

  defp build_media_llm_context(_conversation_id, nil, text) do
    ReqLLM.Context.new([ReqLLM.Context.user(text)])
  end

  defp build_media_llm_context(conversation_id, message_id, text) do
    history = Chat.build_message_history!(conversation_id, message_id, false)
    ReqLLM.Context.new(history ++ [ReqLLM.Context.user(text)])
  rescue
    error ->
      Logger.warning("MediaBypass history load failed: #{Exception.message(error)}")
      ReqLLM.Context.new([ReqLLM.Context.user(text)])
  end

  defp dispatch_media_generation(agent, media_state, mode, conversation_id) do
    case mode do
      :image_generation ->
        case MediaGenerator.generate_image(agent, media_state) do
          {:ok, _agent, _state} ->
            Logger.info("Image generation completed for #{conversation_id}")
            Signals.state_change(conversation_id, :idle)
            Signals.response_complete(conversation_id, %{})

          {:error, _agent, state, error} ->
            MediaGenerator.broadcast_error_event(state, error, "image")
            Signals.state_change(conversation_id, :idle)
            Signals.response_complete(conversation_id, %{})
        end

      :video_generation ->
        # Video generation uses async polling (up to 10 min) — run in a Task
        # so the agent process stays responsive to status checks and new signals.
        Task.Supervisor.start_child(Magus.AgentLoopTaskSupervisor, fn ->
          case MediaGenerator.generate_video(agent, media_state) do
            {:ok, _agent, _state} ->
              Logger.info("Video generation completed for #{conversation_id}")
              Signals.state_change(conversation_id, :idle)
              Signals.response_complete(conversation_id, %{})

            {:error, _agent, state, error} ->
              MediaGenerator.broadcast_error_event(state, error, "video")
              Signals.state_change(conversation_id, :idle)
              Signals.response_complete(conversation_id, %{})
          end
        end)
    end
  end
end
