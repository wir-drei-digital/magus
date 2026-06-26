defmodule Magus.Library do
  @moduledoc """
  Library domain: the prompt library, with prompts, tags, favorites, and
  curated examples backed by pgvector semantic search.
  """

  use Ash.Domain,
    otp_app: :magus,
    extensions: [AshPaperTrail.Domain, AshTypescript.Rpc]

  # Prompt library exposure for the SvelteKit workbench (iteration 6).
  # Public-library browse/copy and semantic search stay LiveView-only for now.
  typescript_rpc do
    resource Magus.Library.Prompt do
      rpc_action :my_prompts, :my_prompts
      rpc_action :my_favorite_prompts, :my_favorite_prompts
      rpc_action :workspace_prompts, :workspace_prompts
      rpc_action :create_prompt, :create
      rpc_action :update_prompt, :update
      rpc_action :destroy_prompt, :destroy
      rpc_action :publish_prompt, :publish
      rpc_action :unpublish_prompt, :unpublish
      rpc_action :share_prompt_to_team, :share_to_team
      rpc_action :unshare_prompt_from_team, :unshare_from_team
      rpc_action :add_prompt_tags, :add_tags
      rpc_action :remove_prompt_tag, :remove_tag
      rpc_action :increment_prompt_use_count, :increment_use_count

      rpc_action :get_prompt, :read do
        get_by [:id]
      end
    end

    resource Magus.Library.Tag do
      rpc_action :list_tags, :read
    end

    resource Magus.Library.PromptFavorite do
      rpc_action :my_prompt_favorites, :my_favorites
      rpc_action :favorite_prompt, :create
      rpc_action :unfavorite_prompt, :destroy
    end
  end

  resources do
    resource Magus.Library.Prompt do
      define :list_prompts, action: :read
      define :my_prompts, action: :my_prompts
      define :workspace_prompts, action: :workspace_prompts, args: [:workspace_id]

      define :workspace_prompts_by_type,
        action: :workspace_prompts_by_type,
        args: [:workspace_id, :type]

      define :my_prompts_by_type, action: :my_prompts_by_type, args: [:type]
      define :my_system_prompts, action: :my_system_prompts
      define :my_user_prompts, action: :my_user_prompts
      define :get_prompt, action: :read, get_by: [:id]
      define :create_prompt, action: :create
      define :update_prompt, action: :update
      define :destroy_prompt, action: :destroy
      define :share_prompt_to_team, action: :share_to_team
      define :unshare_prompt_from_team, action: :unshare_from_team

      # Public library actions
      define :public_prompts, action: :public_prompts
      define :highlighted_prompts, action: :highlighted_prompts
      define :public_search_prompts, action: :public_search
      define :my_favorite_prompts, action: :my_favorite_prompts
      define :publish_prompt, action: :publish
      define :unpublish_prompt, action: :unpublish
      define :copy_prompt_to_library, action: :copy_to_library, args: [:source_prompt_id]
      define :add_prompt_tags, action: :add_tags, args: [:tag_ids]
      define :remove_prompt_tag, action: :remove_tag, args: [:tag_id]

      define :fulltext_search_prompt, action: :fulltext_search, args: [:query]

      define :create_prompt_from_message, action: :create_from_message, args: [:message_id]

      define :create_prompt_from_conversation,
        action: :create_from_conversation,
        args: [:conversation_id]

      define :increment_prompt_use_count, action: :increment_use_count
      define :find_similar_prompts, action: :find_similar, args: [:prompt_id]
    end

    resource Magus.Library.Prompt.Version

    resource Magus.Library.Tag do
      define :list_tags, action: :read
      define :get_tag, action: :read, get_by: [:id]
      define :create_tag, action: :create
      define :get_or_create_tag, action: :get_or_create
      define :destroy_tag, action: :destroy
    end

    resource Magus.Library.PromptTag do
      define :list_prompt_tags, action: :read
      define :create_prompt_tag, action: :create
      define :destroy_prompt_tag, action: :destroy
    end

    resource Magus.Library.PromptFavorite do
      define :list_prompt_favorites, action: :read
      define :my_prompt_favorites, action: :my_favorites
      define :create_prompt_favorite, action: :create
      define :destroy_prompt_favorite, action: :destroy
    end
  end
end
