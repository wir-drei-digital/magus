defmodule Magus.Agents.Dispatcher do
  @moduledoc """
  Signal-native dispatcher for user messages.

  This module replaces the previous DispatchMessage Reactor for conversation
  message delivery. It resolves routing context, ensures the conversation agent
  is running, and emits a single `message.user` signal.
  """

  require Logger

  alias Magus.Agents.Routing.{AutoRouteResolver, ModelKeyResolver}
  alias Magus.Agents.Plugins.Support.Helpers
  alias Magus.Agents.Support.AgentBootstrap

  @conversation_loads [
    :active_system_prompt,
    :selected_model,
    :selected_image_model,
    :selected_video_model,
    custom_agent: [:model, :image_model, :video_model],
    user: [:selected_model, :selected_image_model, :selected_video_model]
  ]

  @type dispatch_result :: %{
          signaled: true,
          signal_type: String.t(),
          agent_id: String.t()
        }

  @spec dispatch_user_message(map()) :: {:ok, dispatch_result()} | {:error, term()}
  def dispatch_user_message(%{conversation_id: conversation_id, created_by_id: user_id} = message) do
    dispatch_message(message, conversation_id, user_id)
  end

  @doc """
  Dispatch a message to the conversation agent.

  The `_user_id` parameter is unused (the user is resolved from the loaded
  conversation) but kept for backward compatibility with existing callers.
  """
  @spec dispatch_message(map(), term(), term()) :: {:ok, dispatch_result()} | {:error, term()}
  def dispatch_message(message, conversation_id, _user_id) do
    with :ok <- check_compaction_lock(conversation_id),
         {:ok, conversation} <- load_conversation(conversation_id),
         {:ok, model_keys} <- resolve_model_keys(conversation),
         {:ok, routed} <- auto_route(model_keys, message, conversation),
         {:ok, agent_info} <-
           ensure_conversation_agent(conversation_id, conversation, message, routed),
         {:ok, signal} <- build_message_signal(message, conversation, routed),
         :ok <- send_signal(agent_info.pid, signal) do
      {:ok, %{signaled: true, signal_type: signal.type, agent_id: agent_info.agent_id}}
    end
  end

  @doc false
  def build_signal_data(message, conversation, routed) do
    mode = message.mode || conversation.chat_mode || :chat
    metadata = message.metadata || %{}

    %{
      message_id: to_string(message.id),
      text: message.text,
      attachments: normalize_attachments(message.attachments),
      mode: mode,
      acting_user_id: message.created_by_id,
      selected_model_id: message.selected_model_id,
      routing_reason: routed.routing_reason,
      model_keys: Helpers.normalize_model_keys(routed.model_keys),
      conversation_context: conversation,
      draft_selection: metadata["draft_selection"] || metadata[:draft_selection],
      pdf_selection: metadata["pdf_selection"] || metadata[:pdf_selection],
      service_selection: metadata["service_selection"] || metadata[:service_selection],
      message_selections: metadata["message_selections"] || metadata[:message_selections],
      active_draft_id: metadata["active_draft_id"] || metadata[:active_draft_id],
      brain_id: metadata["brain_id"] || metadata[:brain_id],
      brain_page_id: metadata["brain_page_id"] || metadata[:brain_page_id]
    }
  end

  # Send-lock backstop: refuse to start a turn while a compaction is in flight
  # for this conversation. The composer already disables Send off the same
  # status (Task 18), but a stale tab / racing message could still arrive here.
  #
  # Conservative by design: ALLOW (`:ok`) when there is no ContextWindow row or
  # the status is :idle / :failed; only block on :pending / :running. The read
  # is a system read (authorize?: false) since dispatch runs without a user
  # actor. Any read failure also defaults to ALLOW so the normal send path is
  # never broken by this guard.
  defp check_compaction_lock(conversation_id) do
    case Magus.Chat.get_context_window(conversation_id, authorize?: false) do
      {:ok, %{compaction_status: status}} when status in [:pending, :running] ->
        {:error, {:compaction_in_progress, conversation_id}}

      _ ->
        :ok
    end
  end

  defp load_conversation(conversation_id) do
    Magus.Chat.get_conversation(conversation_id, load: @conversation_loads, authorize?: false)
  end

  defp resolve_model_keys(conversation) do
    ModelKeyResolver.resolve(conversation)
  end

  defp auto_route(model_keys, message, conversation) do
    AutoRouteResolver.resolve(model_keys, message, conversation)
  end

  defp ensure_conversation_agent(conversation_id, conversation, message, routed) do
    _ = {conversation, message, routed}

    case AgentBootstrap.ensure_conversation_agent(conversation_id) do
      {:ok, %{pid: pid, agent_id: agent_id}} ->
        {:ok, %{pid: pid, agent_id: agent_id}}

      {:error, reason} ->
        Logger.error(
          "Dispatcher: failed to ensure conversation agent conv:#{conversation_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp build_message_signal(message, conversation, routed) do
    signal_data = build_signal_data(message, conversation, routed)
    {:ok, Jido.Signal.new!("message.user", signal_data)}
  rescue
    error -> {:error, {:signal_build_failed, error}}
  end

  defp send_signal(pid, signal) do
    Jido.AgentServer.cast(pid, signal)
  end

  defp normalize_attachments(%Ash.NotLoaded{}), do: []
  defp normalize_attachments(attachments) when is_list(attachments), do: attachments
  defp normalize_attachments(_), do: []
end
