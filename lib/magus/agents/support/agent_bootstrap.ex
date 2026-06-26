defmodule Magus.Agents.Support.AgentBootstrap do
  @moduledoc false

  require Logger

  alias Magus.Agents.Plugins.Support.Helpers
  alias Magus.Agents.Routing.ModelKeyResolver

  @conversation_loads [
    :active_system_prompt,
    :selected_model,
    :selected_image_model,
    :selected_video_model,
    custom_agent: [:model, :image_model, :video_model],
    user: [:selected_model, :selected_image_model, :selected_video_model]
  ]

  @spec ensure_conversation_agent(String.t() | Ecto.UUID.t(), keyword()) ::
          {:ok, %{pid: pid(), agent_id: String.t(), conversation: any(), model_keys: map()}}
          | {:error, term()}
  def ensure_conversation_agent(conversation_id, opts \\ []) do
    manager_name = Keyword.get(opts, :manager, :conversations)
    model_key_override = Keyword.get(opts, :model_key)

    with {:ok, conversation} <-
           Magus.Chat.get_conversation(conversation_id,
             load: @conversation_loads,
             authorize?: false
           ),
         {:ok, model_keys} <- ModelKeyResolver.resolve(conversation) do
      # When the resolver returns :auto for chat and a model_key override is
      # provided (e.g. from an AgentRun record), use the override instead.
      model_keys =
        if model_keys[:chat] == :auto and is_binary(model_key_override) do
          Map.put(model_keys, :chat, model_key_override)
        else
          model_keys
        end

      with {:ok, pid} <- ensure_instance(conversation, model_keys, manager_name) do
        {:ok,
         %{
           pid: pid,
           agent_id: "conv:#{conversation.id}",
           conversation: conversation,
           model_keys: Helpers.normalize_model_keys(model_keys)
         }}
      end
    end
  end

  defp ensure_instance(conversation, model_keys, manager_name) do
    agent_id = "conv:#{conversation.id}"

    initial_state = %{
      conversation_id: to_string(conversation.id),
      user_id: to_string(conversation.user_id),
      model_keys: Helpers.normalize_model_keys(model_keys),
      mode: conversation.chat_mode || :chat,
      model: model_keys[:chat]
    }

    try do
      Jido.Agent.InstanceManager.get(manager_name, agent_id, initial_state: initial_state)
    rescue
      error in ArgumentError ->
        Logger.error(
          "AgentBootstrap: conversation registry unavailable for #{agent_id}: #{Exception.message(error)}"
        )

        {:error, {:registry_unavailable, Exception.message(error)}}
    end
  end
end
