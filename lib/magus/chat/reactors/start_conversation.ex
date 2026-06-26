defmodule Magus.Chat.Reactors.StartConversation do
  @moduledoc """
  Orchestrates the creation of a new conversation with all related setup.

  This reactor:
  1. Creates the conversation with optional initial settings
  2. Applies a system prompt if specified
  3. Ensures the ConversationAgent is ready

  ## Usage

      Reactor.run(Magus.Chat.Reactors.StartConversation, %{
        user_id: user.id,
        title: "My Conversation",
        chat_mode: :chat,
        system_prompt_id: prompt.id
      })

  ## Inputs

  - `user_id` - UUID of the user creating the conversation (required)
  - `title` - Optional title for the conversation
  - `chat_mode` - Chat mode (:chat, :search, :reasoning, :image_generation, :video_generation)
  - `system_prompt_id` - Optional system prompt to activate
  - `folder_id` - Optional folder to place the conversation in

  ## Returns

      {:ok, %Magus.Chat.Conversation{}}
  """

  use Ash.Reactor

  require Logger

  # =============================================================================
  # Inputs
  # =============================================================================

  input :user_id
  input :title
  input :chat_mode
  input :system_prompt_id
  input :folder_id

  # =============================================================================
  # Step 1: Create the conversation
  # =============================================================================

  step :conversation do
    argument :user_id, input(:user_id)
    argument :title, input(:title)
    argument :chat_mode, input(:chat_mode)
    argument :folder_id, input(:folder_id)

    run fn args, _context ->
      # Load user as actor for relate_actor in create action
      {:ok, user} = Magus.Accounts.get_user(args.user_id, authorize?: false)

      attrs = %{
        title: args.title,
        chat_mode: args.chat_mode,
        folder_id: args.folder_id
      }

      # Use domain function with actor (for relate_actor)
      Magus.Chat.create_conversation(attrs, actor: user)
    end
  end

  # =============================================================================
  # Step 2: Apply system prompt if specified
  # =============================================================================

  step :apply_system_prompt do
    argument :conversation, result(:conversation)
    argument :system_prompt_id, input(:system_prompt_id)

    run fn args, _context ->
      case args.system_prompt_id do
        nil ->
          {:ok, args.conversation}

        prompt_id ->
          case Magus.Chat.activate_system_prompt(args.conversation, prompt_id, authorize?: false) do
            {:ok, updated} -> {:ok, updated}
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  # =============================================================================
  # Step 3: Pre-warm ConversationAgent (optional, non-blocking)
  # =============================================================================

  step :prewarm_conversation_agent do
    argument :conversation, result(:apply_system_prompt)
    argument :user_id, input(:user_id)

    run fn args, _context ->
      # Pre-warming is optional - the agent will be started on first message anyway
      # This just reduces latency for the first message
      agent_id = "conv:#{args.conversation.id}"

      try do
        case Jido.Agent.InstanceManager.get(:conversations, agent_id,
               initial_state: %{
                 conversation_id: to_string(args.conversation.id),
                 user_id: to_string(args.user_id),
                 model_keys: %{chat: nil, image: nil, video: nil},
                 mode: args.conversation.chat_mode || :chat
               }
             ) do
          {:ok, _pid} ->
            Logger.debug("StartConversation: Pre-warmed agent #{agent_id}")
            {:ok, :prewarmed}

          {:error, _reason} ->
            {:ok, :skipped}
        end
      rescue
        _ -> {:ok, :skipped}
      end
    end
  end

  # =============================================================================
  # Return the conversation
  # =============================================================================

  return :apply_system_prompt
end
