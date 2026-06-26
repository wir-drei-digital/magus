defmodule Magus.Agents.Context.ConversationState do
  @moduledoc """
  State struct for conversation agent processing.

  Holds all the context needed during a single agent response cycle:
  model info, accumulated text, tool state, user/conversation references, etc.

  Originally defined inside the legacy monolithic strategy; extracted here
  so that modules like `MessagePersistence`, `MediaGenerator`, and
  `MentionDispatcher` can reference it without depending on a strategy module.
  """

  defstruct [
    :status,
    :phase,
    :correlation_id,
    :conversation_id,
    :user_id,
    :model_keys,
    :mode,
    :iteration,
    :max_iterations,
    :accumulated_text,
    :accumulated_thinking,
    :reasoning_details,
    :pending_tool_calls,
    :current_message_id,
    :parent_message_id,
    :llm_context,
    :tools,
    :tool_contexts,
    :model_record,
    :conversation,
    :user_record,
    :usage,
    :finish_reason,
    :citations,
    :custom_agent_id,
    :custom_agent_name,
    :action_cards,
    attachments: [],
    scope: :default
  ]
end
