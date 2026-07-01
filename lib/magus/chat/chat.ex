defmodule Magus.Chat do
  @moduledoc """
  Chat domain: AI conversations and their messages, the model catalog,
  per-message usage tracking, folders, and multiplayer sharing/membership.
  The core of the agentic chat experience.
  """

  use Ash.Domain,
    otp_app: :magus,
    extensions: [AshPhoenix, AshAdmin.Domain, AshTypescript.Rpc]

  typescript_rpc do
    resource Magus.Chat.Conversation do
      rpc_action :my_conversations, :my_conversations
      rpc_action :my_favorite_conversations, :my_favorites
      rpc_action :workspace_conversations, :workspace_conversations
      rpc_action :personal_conversations, :personal_conversations
      rpc_action :share_conversation_to_team, :share_to_team
      rpc_action :unshare_conversation_from_team, :unshare_from_team
      rpc_action :move_conversation_to_folder, :move_to_folder
      rpc_action :create_conversation, :create
      rpc_action :start_skill_conversation, :start_skill_conversation
      rpc_action :rename_conversation, :rename
      rpc_action :archive_conversation, :soft_delete
      rpc_action :set_conversation_model, :set_model
      rpc_action :set_conversation_image_model, :set_image_model
      rpc_action :set_conversation_video_model, :set_video_model
      rpc_action :set_conversation_mode, :set_mode
      rpc_action :update_conversation_settings, :update_settings
      rpc_action :update_conversation_image_settings, :update_image_generation_settings
      rpc_action :update_conversation_video_settings, :update_video_generation_settings
      rpc_action :reset_conversation_settings, :reset_settings
      rpc_action :activate_conversation_prompt, :activate_system_prompt
      rpc_action :deactivate_conversation_prompt, :deactivate_system_prompt
      rpc_action :create_thread, :create_thread
      rpc_action :conversation_threads, :threads_for_conversation
      rpc_action :conversations_threads, :threads_for_conversations
      rpc_action :conversation_history, :history
      rpc_action :trashed_conversations, :trashed
      rpc_action :restore_conversation, :restore
      rpc_action :delete_conversation_permanently, :delete_full_conversation
      rpc_action :enable_conversation_multiplayer, :enable_multiplayer
      rpc_action :disable_conversation_multiplayer, :disable_multiplayer
      rpc_action :send_now_queued, :send_now_queued

      rpc_action :get_conversation, :read do
        get_by [:id]
      end
    end

    resource Magus.Chat.ConversationShareLink do
      rpc_action :conversation_share_links, :active_for_conversation
      rpc_action :create_share_link, :create
      rpc_action :revoke_share_link, :revoke
    end

    resource Magus.Chat.ConversationMember do
      rpc_action :conversation_members, :for_conversation
      rpc_action :change_member_role, :change_role
      rpc_action :mute_conversation_member, :mute
      rpc_action :unmute_conversation_member, :unmute
      rpc_action :remove_conversation_member, :destroy
    end

    resource Magus.Chat.ConversationInvitation do
      rpc_action :invite_to_conversation, :create
      rpc_action :pending_conversation_invitations, :pending_for_conversation
      rpc_action :cancel_conversation_invitation, :destroy
    end

    resource Magus.Chat.ConversationInviteLink do
      rpc_action :conversation_invite_links, :active_for_conversation
      rpc_action :create_conversation_invite_link, :create
      rpc_action :deactivate_conversation_invite_link, :deactivate
    end

    resource Magus.Chat.Message do
      rpc_action :message_history, :for_conversation
      rpc_action :messages_since, :since
      rpc_action :send_user_message, :send_user_message
      rpc_action :enqueue_message, :enqueue_message
      rpc_action :remove_queued, :remove_queued
      rpc_action :delete_message, :destroy
      rpc_action :toggle_message_disabled, :toggle_disabled
    end

    resource Magus.Chat.Model do
      rpc_action :list_active_models, :list_active
      rpc_action :list_image_generation_models, :list_image_generation
      rpc_action :list_video_generation_models, :list_video_generation
    end

    resource Magus.Chat.ConversationFavorite do
      rpc_action :my_conversation_favorites, :my_favorites
      rpc_action :favorite_conversation, :create
      rpc_action :unfavorite_conversation, :destroy
      rpc_action :remove_conversation_favorite, :unfavorite_by_conversation
    end

    resource Magus.Chat.UserModelPreference do
      rpc_action :my_model_preferences, :my_model_preferences
      rpc_action :set_model_favorite, :set_favorite
      rpc_action :set_model_hidden, :set_hidden
      rpc_action :set_model_position, :set_position
    end

    # File-browser folder tree (migration iteration 5). promote_to_mixed is
    # intentionally NOT exposed — it auto-triggers via PromoteKindForContent
    # when content moves into an opposite-kind folder.
    resource Magus.Chat.Folder do
      rpc_action :my_folders, :my_folders
      rpc_action :workspace_folders, :workspace_folders
      rpc_action :folder_children, :list_in_folder
      rpc_action :create_folder, :create
      rpc_action :rename_folder, :update
      rpc_action :move_folder, :move_to_folder
      rpc_action :delete_folder, :destroy
      rpc_action :share_folder_to_team, :share_to_team
      rpc_action :unshare_folder_from_team, :unshare_from_team

      rpc_action :get_folder, :read do
        get_by [:id]
      end
    end

    # "Open chat" companion button on files and brain pages.
    resource Magus.Chat.ConversationCompanion do
      rpc_action :open_companion_chat, :find_or_create_companion_chat
    end

    # Chat-nav folder expansion, persisted per user (classic parity).
    resource Magus.Chat.UserFolderState do
      rpc_action :my_folder_states, :my_folder_states
      rpc_action :upsert_folder_expanded, :upsert
    end

    # Per-conversation context-window donut: read the token snapshot + the
    # Clear / Compact / strategy controls, keyed by conversation_id.
    resource Magus.Chat.ContextWindow do
      rpc_action :get_context_window, :get_for_conversation do
        get_by [:conversation_id]
      end

      rpc_action :clear_context_window, :clear_for_conversation
      rpc_action :compact_context_window, :compact_for_conversation
      rpc_action :set_context_strategy, :set_strategy_for_conversation
    end
  end

  resources do
    resource Magus.Chat.Message do
      define :message_history,
        action: :for_conversation,
        args: [:conversation_id],
        default_options: [query: [sort: [inserted_at: :desc]]]

      define :list_messages_for_llm_context,
        action: :for_llm_context,
        args: [:conversation_id, :exclude_id, {:optional, :cutoff_at}]

      define :create_message, action: :create
      define :send_user_message, action: :send_user_message
      define :enqueue_message, action: :enqueue_message, args: [:conversation_id]
      define :flush_queued_message, action: :flush_queued
      define :remove_queued_message, action: :remove_queued
      define :list_queued_messages, action: :queued_for_conversation, args: [:conversation_id]
      define :get_message, action: :read, get_by: [:id]
      define :toggle_message_disabled, action: :toggle_disabled
      define :mark_message_stopped, action: :mark_stopped
      define :mark_message_error, action: :mark_error
      define :create_event_message, action: :create_event, args: [:text, :conversation_id]
      define :update_event_message, action: :update_event_message

      define :create_job_trigger_message,
        action: :create_job_trigger,
        args: [:text, :conversation_id, :job_id, :job_name, :memory_name]

      define :create_draft_event_message,
        action: :create_draft_event,
        args: [:text, :conversation_id, :draft_action, :draft_id]

      define :fulltext_search_message, action: :fulltext_search, args: [:query]

      define :search_messages_in_conversation,
        action: :search_in_conversation,
        args: [:conversation_id, :query]

      define :messages_since, action: :since, args: [:conversation_id, :since]

      define :upsert_event_message,
        action: :upsert_event,
        args: [:id, :text, :conversation_id, :tool_call_data, :complete]
    end

    resource Magus.Chat.Model do
      define :list_active_models, action: :list_active
      define :list_provider_linked_active_models, action: :list_provider_linked_active
      define :list_image_generation_models, action: :list_image_generation
      define :list_video_generation_models, action: :list_video_generation
      define :get_model, action: :read, get_by: [:id]
      define :get_model_by_name, action: :by_name, args: [:name]
      define :get_model_by_key_with_provider, action: :by_key_with_provider, args: [:key]
      define :create_owned_model, action: :create_owned
      define :list_owned_models, action: :owned
    end

    resource Magus.Chat.RoutingSlot do
      define :list_routing_slots, action: :list_all
      define :upsert_routing_slot, action: :upsert_slot, args: [:model_id, :specialty, :tier]
      define :delete_routing_slot, action: :destroy
    end

    resource Magus.Chat.ContextWindow do
      define :get_or_create_context_window, action: :get_or_create, args: [:conversation_id]
      define :get_context_window, action: :get_for_conversation, args: [:conversation_id]
      define :upsert_context_snapshot, action: :upsert_snapshot
      define :patch_context_usage, action: :patch_usage
      define :set_context_strategy, action: :set_strategy
      define :clear_context_window, action: :clear
      define :request_context_compaction, action: :request_compaction
      define :mark_context_compacting, action: :mark_compacting
      define :compact_context_window, action: :compact
      define :mark_context_compaction_failed, action: :mark_failed

      # Conversation-keyed shared operations (LiveView donut + SPA RPC).
      define :clear_context_for_conversation,
        action: :clear_for_conversation,
        args: [:conversation_id]

      define :compact_context_for_conversation,
        action: :compact_for_conversation,
        args: [:conversation_id]

      define :set_context_strategy_for_conversation,
        action: :set_strategy_for_conversation,
        args: [:conversation_id, :strategy]
    end

    resource Magus.Chat.Conversation do
      define :create_conversation, action: :create
      define :get_conversation, action: :read, get_by: [:id]
      define :my_conversations
      define :my_task_conversations
      define :unfiled_conversations
      define :filed_conversations
      define :workspace_conversations, args: [:workspace_id]
      define :personal_conversations, action: :personal_conversations
      define :move_conversation_to_folder, action: :move_to_folder
      define :soft_delete_conversation, action: :soft_delete
      define :restore_conversation, action: :restore
      define :delete_full_conversation, action: :delete_full_conversation
      define :trashed_conversations, action: :trashed
      define :enable_multiplayer, action: :enable_multiplayer
      define :rename_conversation, action: :rename
      define :send_now_queued, action: :send_now_queued, args: [:conversation_id]
      define :update_conversation_visibility, action: :update_visibility
      define :share_conversation_to_team, action: :share_to_team
      define :unshare_conversation_from_team, action: :unshare_from_team
      define :set_conversation_mode, action: :set_mode
      define :update_image_generation_settings, action: :update_image_generation_settings
      define :update_video_generation_settings, action: :update_video_generation_settings
      define :set_conversation_model, action: :set_model
      define :set_conversation_image_model, action: :set_image_model
      define :set_conversation_video_model, action: :set_video_model
      define :update_conversation_settings, action: :update_settings
      define :reset_conversation_settings, action: :reset_settings
      define :activate_system_prompt, action: :activate_system_prompt, args: [:prompt_id]
      define :deactivate_system_prompt, action: :deactivate_system_prompt
      define :set_conversation_skill, action: :set_skill
      define :set_conversation_loaded_tools, action: :set_loaded_tools
      define :record_skill_approval, action: :record_skill_approval
      define :schedule_extraction, action: :schedule_extraction
      define :mark_memory_consolidated, action: :mark_memory_consolidated

      define :build_message_history,
        args: [
          :conversation_id,
          :current_message_id,
          {:optional, :is_multiplayer}
        ]

      define :build_thread_message_history,
        args: [
          :conversation_id,
          :current_message_id,
          {:optional, :is_multiplayer}
        ]

      define :fulltext_search_conversation, action: :fulltext_search, args: [:query]
      define :my_favorite_conversations, action: :my_favorites
      define :personal_favorite_conversations, action: :personal_favorites

      define :workspace_favorite_conversations,
        action: :workspace_favorites,
        args: [:workspace_id]

      define :disable_multiplayer
      define :create_thread, action: :create_thread
      define :threads_for_conversation, args: [:conversation_id]
      define :threads_for_conversations, args: [:conversation_ids]
    end

    resource Magus.Chat.ConversationMember do
      define :add_conversation_member, action: :add_member, args: [:conversation_id, :user_id]
      define :add_conversation_owner, action: :add_owner, args: [:conversation_id, :user_id]
      define :accept_conversation_invitation, action: :accept_invitation
      define :change_member_role, action: :change_role
      define :mute_member, action: :mute
      define :unmute_member, action: :unmute
      define :get_conversation_members, action: :for_conversation, args: [:conversation_id]

      define :get_accepted_members,
        action: :accepted_for_conversation,
        args: [:conversation_id]

      define :my_conversation_memberships, action: :my_memberships
      define :my_pending_invitations, action: :pending_invitations
      define :remove_conversation_member, action: :destroy
    end

    resource Magus.Chat.ConversationInviteLink do
      define :create_invite_link, action: :create, args: [:conversation_id]
      define :get_invite_link_by_token, action: :by_token, args: [:token]
      define :get_conversation_invite_links, action: :for_conversation, args: [:conversation_id]

      define :get_active_invite_links,
        action: :active_for_conversation,
        args: [:conversation_id]

      define :update_invite_link, action: :update
      define :deactivate_invite_link, action: :deactivate
      define :increment_link_uses, action: :increment_uses
      define :delete_invite_link, action: :destroy
    end

    resource Magus.Chat.ConversationInvitation do
      define :create_invitation, action: :create, args: [:conversation_id]
      define :get_invitation_by_token, action: :by_token, args: [:token]
      define :get_invitation_by_email, action: :by_email, args: [:email, :conversation_id]
      define :get_pending_invitations, action: :pending_for_conversation, args: [:conversation_id]
      define :accept_invitation, action: :accept
      define :delete_invitation, action: :destroy
    end

    resource Magus.Chat.Folder do
      define :create_folder, action: :create
      define :get_folder, action: :read, get_by: [:id]
      define :update_folder, action: :update
      define :promote_folder_to_mixed, action: :promote_to_mixed
      define :move_folder, action: :move_to_folder
      define :my_folders
      define :list_workspace_folders, action: :list_for_workspace, args: [:workspace_id]
      define :list_folders_in_folder, action: :list_in_folder, args: [:parent_id]
      define :root_folders
      define :delete_folder, action: :destroy
      define :share_folder_to_team, action: :share_to_team
      define :unshare_folder_from_team, action: :unshare_from_team
    end

    resource Magus.Chat.UserFolderState do
      define :upsert_folder_expanded, action: :upsert
      define :my_folder_states
    end

    resource Magus.Chat.ConversationShareLink do
      define :create_share_link, action: :create, args: [:conversation_id]
      define :revoke_share_link, action: :revoke
      define :delete_share_link, action: :destroy
      define :get_share_link_by_token, action: :by_token, args: [:token]
      define :get_active_share_links, action: :active_for_conversation, args: [:conversation_id]
    end

    resource Magus.Chat.ConversationFavorite do
      define :create_conversation_favorite, action: :create
      define :destroy_conversation_favorite, action: :destroy
      define :my_conversation_favorites, action: :my_favorites

      define :get_conversation_favorite,
        action: :by_conversation,
        args: [:conversation_id],
        get?: true
    end

    resource Magus.Chat.UserModelPreference do
      define :my_model_preferences, action: :my_model_preferences
      define :set_model_favorite, action: :set_favorite
      define :set_model_hidden, action: :set_hidden
      define :set_model_position, action: :set_position
      define :destroy_model_preference, action: :destroy
    end

    resource Magus.Chat.PaneState do
      define :get_pane_state,
        action: :by_conversation_and_user,
        args: [:conversation_id, :user_id],
        get?: true,
        not_found_error?: false

      define :set_pane, action: :set, args: [:conversation_id, :user_id, :pane_type, :resource_id]
      define :dismiss_pane, action: :dismiss, args: [:conversation_id, :user_id]
    end

    resource Magus.Chat.ConversationCompanion do
      define :get_companion_by_resource,
        action: :by_resource,
        args: [:resource_type, :resource_id]

      define :get_companion_by_conversation,
        action: :by_conversation_id,
        args: [:conversation_id]

      define :find_or_create_companion_link,
        action: :find_or_create_companion,
        args: [:resource_type, :resource_id]
    end
  end

  @doc """
  Find-or-create the companion conversation linked to the given resource for
  the actor. Returns `{:ok, %Conversation{}}` or `{:error, _}`.
  """
  def find_or_create_companion_conversation(resource_type, resource_id, opts) do
    case find_or_create_companion_link(resource_type, resource_id, opts) do
      {:ok, %{conversation: %Magus.Chat.Conversation{} = conv}} -> {:ok, conv}
      {:error, _} = err -> err
    end
  end

  @doc """
  System sweep: drops all `ConversationCompanion` rows for the given resource
  across all users. Called from `File`/`BrainPage` destroy after_actions when
  the underlying resource is deleted. Returns `:ok` on success.

  This bypasses authorization because resource deletion must clean up links
  belonging to users other than the current actor.
  """
  def unlink_companion_for_resource(resource_type, resource_id) do
    input =
      Ash.ActionInput.for_action(
        Magus.Chat.ConversationCompanion,
        :destroy_for_resource,
        %{resource_type: resource_type, resource_id: resource_id}
      )

    case Ash.run_action(input, authorize?: false) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, _} = err -> err
    end
  end
end
