defmodule Magus.Accounts do
  @moduledoc """
  Accounts domain: users, authentication (password + magic link via
  AshAuthentication), profile and UI settings, and workspace selection.
  """

  use Ash.Domain, otp_app: :magus, extensions: [AshTypescript.Rpc]

  typescript_rpc do
    resource Magus.Accounts.User do
      rpc_action :current_user, :current_user
      rpc_action :update_ui_preferences, :update_ui_preferences
      rpc_action :select_workspace, :select_workspace

      # Settings — profile
      rpc_action :update_user_settings, :update_settings
      rpc_action :request_email_change, :request_email_change
      rpc_action :change_user_password, :change_password
      rpc_action :set_user_password, :set_password

      # Settings — preferences
      rpc_action :select_default_model, :select_model
      rpc_action :select_default_image_model, :select_image_model
      rpc_action :select_default_video_model, :select_video_model
      rpc_action :update_timezone, :update_timezone
      rpc_action :update_data_region_preference, :update_data_region_preference
      rpc_action :grant_data_region_consent, :grant_data_region_consent

      # Settings: memory
      rpc_action :update_global_memory_setting, :update_global_memory_setting
      rpc_action :update_profile_setting, :update_profile_setting
    end
  end

  resources do
    resource Magus.Accounts.Token

    resource Magus.Accounts.ApiToken do
      define :get_api_token, action: :read, get_by: [:id]
      define :list_api_tokens, action: :list_for_actor
      define :get_api_token_by_hash, action: :get_by_hash, args: [:key_hash]
      define :revoke_api_token, action: :revoke
      define :touch_api_token, action: :touch_last_used_at
    end

    resource Magus.Accounts.User do
      define :select_workspace, action: :select_workspace, args: [:current_workspace_id]
      define :select_model, action: :select_model, args: [:selected_model_id]
      define :select_image_model, action: :select_image_model, args: [:selected_image_model_id]
      define :select_video_model, action: :select_video_model, args: [:selected_video_model_id]
      define :update_image_generation_settings, action: :update_image_generation_settings
      define :update_video_generation_settings, action: :update_video_generation_settings
      define :get_by_email, action: :get_by_email, args: [:email]
      define :get_user, action: :read, get_by: [:id]
      define :create_test_user, action: :admin_create_test_user
      define :update_user_settings, action: :update_settings
      define :update_avatar, action: :update_avatar, args: [:avatar_path]
      define :delete_avatar, action: :delete_avatar
      define :update_ui_preferences, action: :update_ui_preferences, args: [:ui_preferences]
      define :update_timezone, action: :update_timezone, args: [:timezone]
      define :clear_selected_plan, action: :clear_selected_plan
      define :request_email_change, action: :request_email_change, args: [:new_email]
      define :confirm_email_change, action: :confirm_email_change, args: [:token]
      define :change_user_password, action: :change_password
      define :set_user_password, action: :set_password
      define :complete_profile, action: :complete_profile

      define :update_data_region_preference,
        action: :update_data_region_preference,
        args: [:regions]

      define :grant_data_region_consent, action: :grant_data_region_consent, args: [:region]
    end
  end

  @doc """
  Creates an API token and returns both the record and the one-time plaintext.

  Plaintext is generated inside the create action's change and stored on the
  returned record's `__metadata__`. It is only available from this wrapper's
  return value and never persisted.
  """
  def create_api_token(attrs, opts) do
    case Magus.Accounts.ApiToken
         |> Ash.Changeset.for_create(:create, attrs, opts)
         |> Ash.create() do
      {:ok, token} ->
        {:ok, %{token: token, plaintext: token.__metadata__[:plaintext]}}

      {:error, _} = err ->
        err
    end
  end
end
