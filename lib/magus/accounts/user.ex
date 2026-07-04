defmodule Magus.Accounts.User do
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication, AshOban, AshTypescript.Resource]

  authentication do
    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end

      confirmation :confirm_new_user do
        monitor_fields [:email]
        confirm_on_create? true
        confirm_on_update? false
        require_interaction? true
        confirmed_at_field :confirmed_at

        auto_confirm_actions [
          :sign_in_with_magic_link,
          :reset_password_with_token,
          :admin_create_test_user
        ]

        sender Magus.Accounts.User.Senders.SendNewUserConfirmationEmail
      end
    end

    tokens do
      enabled? true
      token_resource Magus.Accounts.Token
      signing_secret Magus.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end

    strategies do
      password :password do
        identity_field :email
        hash_provider AshAuthentication.BcryptProvider

        resettable do
          sender Magus.Accounts.User.Senders.SendPasswordResetEmail
          # these configurations will be the default in a future release
          password_reset_action_name :reset_password_with_token
          request_password_reset_action_name :request_password_reset_token
        end
      end

      magic_link do
        identity_field :email
        registration_enabled? true
        require_interaction? true

        sender Magus.Accounts.User.Senders.SendMagicLinkEmail
      end

      remember_me do
        token_lifetime {30, :days}
      end
    end
  end

  postgres do
    table "users"
    repo Magus.Repo
  end

  oban do
    triggers do
      trigger :consolidate_memories do
        action :trigger_memory_consolidation
        queue :memory_consolidation
        scheduler_cron "0 3 * * *"
        read_action :read_for_consolidation
        worker_read_action :read_for_consolidation
        worker_module_name Magus.Accounts.User.Workers.ConsolidateMemories
        scheduler_module_name Magus.Accounts.User.Schedulers.ConsolidateMemories
        where expr(global_memory_enabled == true)
        max_scheduler_attempts 1
        max_attempts 2
      end
    end
  end

  typescript do
    type_name "User"
  end

  actions do
    defaults [:read]

    read :current_user do
      description "Read the authenticated user (the actor). Used by the RPC layer."
      get? true
      filter expr(id == ^actor(:id))
    end

    # Explicitly define the :confirm action so we can add the welcome email change.
    # AshAuthentication generates this action from the :confirm_new_user add-on
    # with confirm_action_name defaulting to :confirm. By defining it ourselves,
    # the transformer skips building it but validates the required changes exist.
    update :confirm do
      require_atomic? false
      accept [:email]

      argument :confirm, :string do
        allow_nil? false
        public? true
      end

      change AshAuthentication.AddOn.Confirmation.ConfirmChange
      change AshAuthentication.GenerateTokenChange
      change Magus.Accounts.User.Changes.SendWelcomeEmail

      metadata :token, :string do
        allow_nil? false
      end
    end

    read :read_for_consolidation do
      description "Read action for memory consolidation scheduler"
      pagination keyset?: true, required?: false
    end

    # AshOban target for the :consolidate_memories trigger. Must be an update action
    # (not a generic action): AshOban loads the user record for update/destroy triggers
    # and exposes its id to the side-effecting work. A generic action only receives the
    # row's primary key under a "primary_key" input, which is dropped by
    # skip_unknown_inputs, leaving any required user_id argument unset.
    update :trigger_memory_consolidation do
      description "Runs daily memory consolidation for the user (AshOban trigger target)"
      accept []
      transaction? false
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, user ->
          case Magus.Agents.Actions.ConsolidateMemories.run(
                 %{user_id: to_string(user.id)},
                 %{}
               ) do
            {:ok, _result} ->
              {:ok, user}

            {:error, reason} ->
              require Logger

              Logger.warning(
                "Memory consolidation failed for user #{user.id}: #{inspect(reason)}"
              )

              {:ok, user}
          end
        end)
      end
    end

    update :select_workspace do
      accept [:current_workspace_id]
      require_atomic? false

      validate fn changeset, context ->
        workspace_id = Ash.Changeset.get_attribute(changeset, :current_workspace_id)

        case context.actor do
          %{id: actor_id} ->
            if is_nil(workspace_id) ||
                 Magus.Checks.Helpers.active_workspace_member?(workspace_id, actor_id) do
              :ok
            else
              {:error,
               field: :current_workspace_id,
               message: "must be an active workspace the actor belongs to"}
            end

          _ ->
            {:error, field: :current_workspace_id, message: "actor is required"}
        end
      end
    end

    update :select_model do
      accept [:selected_model_id]
      require_atomic? false
      validate {Magus.Chat.Model.Validations.SelectableByActor, attribute: :selected_model_id}
    end

    update :select_image_model do
      accept [:selected_image_model_id]
      require_atomic? false

      validate {Magus.Chat.Model.Validations.SelectableByActor,
                attribute: :selected_image_model_id}
    end

    update :select_video_model do
      accept [:selected_video_model_id]
      require_atomic? false

      validate {Magus.Chat.Model.Validations.SelectableByActor,
                attribute: :selected_video_model_id}
    end

    update :update_image_generation_settings do
      accept [:image_generation_settings]
      require_atomic? false

      change fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :image_generation_settings) do
          nil ->
            changeset

          settings ->
            Ash.Changeset.force_change_attribute(
              changeset,
              :image_generation_settings,
              Magus.Agents.ImageGenerationConfig.sanitize(settings)
            )
        end
      end
    end

    update :update_video_generation_settings do
      accept [:video_generation_settings]
      require_atomic? false

      change fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :video_generation_settings) do
          nil ->
            changeset

          settings ->
            Ash.Changeset.force_change_attribute(
              changeset,
              :video_generation_settings,
              Magus.Agents.VideoGenerationConfig.sanitize(settings)
            )
        end
      end
    end

    update :update_profile do
      accept [:display_name]
    end

    update :update_settings do
      description "Update user settings like display name, language, and name"
      accept [:display_name, :language, :name, :context_strategy]
    end

    update :complete_profile do
      description "Complete user profile after magic link sign-in (name + consent)"
      require_atomic? false
      accept [:name, :display_name]

      argument :accepted_terms, :boolean do
        allow_nil? false
      end

      argument :accepted_age_requirement, :boolean do
        allow_nil? false
      end

      validate fn changeset, _context ->
        if Ash.Changeset.get_argument(changeset, :accepted_terms) == true do
          :ok
        else
          {:error, field: :accepted_terms, message: "must be accepted"}
        end
      end

      validate fn changeset, _context ->
        if Ash.Changeset.get_argument(changeset, :accepted_age_requirement) == true do
          :ok
        else
          {:error, field: :accepted_age_requirement, message: "must be accepted"}
        end
      end

      change set_attribute(:accepted_terms, arg(:accepted_terms))
      change set_attribute(:accepted_age_requirement, arg(:accepted_age_requirement))
      change Magus.Accounts.User.Changes.SendWelcomeEmail
    end

    update :update_avatar do
      description "Update user's avatar path"
      accept [:avatar_path]
    end

    update :update_ui_preferences do
      description "Update user's UI preferences (card states, etc.)"
      accept [:ui_preferences]
    end

    update :update_global_memory_setting do
      description "Enable or disable global memory"
      accept [:global_memory_enabled]
    end

    update :clear_selected_plan do
      description "Clear the selected_plan_key after successful checkout"
      change set_attribute(:selected_plan_key, nil)
    end

    update :update_timezone do
      description "Update user's timezone preference"
      require_atomic? false
      accept [:timezone]

      # Validate timezone format
      validate fn changeset, _context ->
        tz = Ash.Changeset.get_attribute(changeset, :timezone)

        cond do
          is_nil(tz) or tz == "" ->
            :ok

          tz in ["UTC", "Etc/UTC"] ->
            :ok

          # Check if it looks like a valid IANA timezone format (Area/Location)
          Regex.match?(~r/^[A-Za-z_]+\/[A-Za-z_\/]+$/, tz) ->
            # Try to validate with tzdata if available, otherwise accept the format
            case DateTime.shift_zone(DateTime.utc_now(), tz) do
              {:ok, _} -> :ok
              # Accept if tzdata isn't configured - full validation happens at use time
              {:error, :time_zone_not_found} -> :ok
              {:error, :utc_only_time_zone_database} -> :ok
              {:error, _} -> {:error, field: :timezone, message: "Invalid timezone"}
            end

          true ->
            {:error,
             field: :timezone,
             message: "Invalid timezone format. Use IANA format like 'America/New_York'"}
        end
      end

      # Rate limit timezone changes (30 days between changes)
      validate fn changeset, _context ->
        if Ash.Changeset.changing_attribute?(changeset, :timezone) do
          last_change = changeset.data.last_timezone_change_at
          min_days = 30

          cond do
            is_nil(last_change) ->
              :ok

            DateTime.diff(DateTime.utc_now(), last_change, :day) >= min_days ->
              :ok

            true ->
              days_remaining = min_days - DateTime.diff(DateTime.utc_now(), last_change, :day)

              {:error,
               field: :timezone,
               message: "You can change your timezone again in #{days_remaining} days"}
          end
        else
          :ok
        end
      end

      # Update last_timezone_change_at when timezone changes
      change fn changeset, _context ->
        if Ash.Changeset.changing_attribute?(changeset, :timezone) do
          Ash.Changeset.force_change_attribute(
            changeset,
            :last_timezone_change_at,
            DateTime.utc_now()
          )
        else
          changeset
        end
      end
    end

    update :delete_avatar do
      description "Delete user's avatar"
      require_atomic? false
      accept []

      change before_action(fn changeset, _context ->
               if old_path = changeset.data.avatar_path do
                 Magus.Files.Storage.delete(old_path)
               end

               changeset
             end)

      change set_attribute(:avatar_path, nil)
    end

    update :request_email_change do
      description "Request to change email address - sends confirmation to new email"
      require_atomic? false
      accept []

      argument :new_email, :ci_string, allow_nil?: false

      # Validate email is not already taken
      validate fn changeset, _context ->
        new_email = Ash.Changeset.get_argument(changeset, :new_email)

        case Magus.Accounts.get_by_email(new_email, authorize?: false) do
          {:ok, _user} -> {:error, field: :new_email, message: "is already taken"}
          {:error, _} -> :ok
        end
      end

      change set_attribute(:pending_email, arg(:new_email))

      change after_action(fn changeset, user, _context ->
               new_email = Ash.Changeset.get_argument(changeset, :new_email)

               token =
                 Phoenix.Token.sign(
                   MagusWeb.Endpoint,
                   "email_change",
                   {user.id, to_string(new_email)}
                 )

               Magus.Accounts.User.Senders.SendEmailChangeConfirmationEmail.send(
                 user,
                 new_email,
                 token
               )

               {:ok, user}
             end)
    end

    update :confirm_email_change do
      description "Confirm email change with token"
      require_atomic? false
      accept []

      argument :token, :string, allow_nil?: false, sensitive?: true

      validate fn changeset, _context ->
        token = Ash.Changeset.get_argument(changeset, :token)
        user = changeset.data

        # Token is valid for 24 hours
        case Phoenix.Token.verify(MagusWeb.Endpoint, "email_change", token, max_age: 86400) do
          {:ok, {user_id, new_email}} when user_id == user.id ->
            # Check the pending_email matches
            if to_string(user.pending_email) == new_email do
              :ok
            else
              {:error, message: "Invalid or expired confirmation link"}
            end

          _ ->
            {:error, message: "Invalid or expired confirmation link"}
        end
      end

      change fn changeset, _context ->
        pending = changeset.data.pending_email

        changeset
        |> Ash.Changeset.change_attribute(:email, pending)
        |> Ash.Changeset.change_attribute(:pending_email, nil)
      end
    end

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    update :change_password do
      # Use this action to allow users to change their password by providing
      # their current password and a new password.

      require_atomic? false
      accept []
      argument :current_password, :string, sensitive?: true, allow_nil?: false

      argument :password, :string,
        sensitive?: true,
        allow_nil?: false,
        constraints: [min_length: 8]

      argument :password_confirmation, :string, sensitive?: true, allow_nil?: false

      validate confirm(:password, :password_confirmation)

      validate {AshAuthentication.Strategy.Password.PasswordValidation,
                strategy_name: :password, password_argument: :current_password}

      change {AshAuthentication.Strategy.Password.HashPasswordChange, strategy_name: :password}
    end

    update :set_password do
      # Use this action to allow users who registered via magic link
      # (and have no password set) to set their initial password.

      require_atomic? false
      accept []

      argument :password, :string,
        sensitive?: true,
        allow_nil?: false,
        constraints: [min_length: 8]

      argument :password_confirmation, :string, sensitive?: true, allow_nil?: false

      validate confirm(:password, :password_confirmation)

      change {AshAuthentication.Strategy.Password.HashPasswordChange, strategy_name: :password}
    end

    read :sign_in_with_password do
      description "Attempt to sign in using a email and password."
      get? true

      argument :email, :ci_string do
        description "The email to use for retrieving the user."
        allow_nil? false
      end

      argument :password, :string do
        description "The password to check for the matching user."
        allow_nil? false
        sensitive? true
      end

      argument :remember_me, :boolean do
        description "Whether to generate a remember me token."
        allow_nil? true
        default false
      end

      # validates the provided email and password and generates a token
      prepare AshAuthentication.Strategy.Password.SignInPreparation
      prepare AshAuthentication.Strategy.RememberMe.MaybeGenerateTokenPreparation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end

      metadata :remember_me, :map do
        description "A map with the remember me token and strategy."
        allow_nil? true
      end
    end

    read :sign_in_with_token do
      # In the generated sign in components, we validate the
      # email and password directly in the LiveView
      # and generate a short-lived token that can be used to sign in over
      # a standard controller action, exchanging it for a standard token.
      # This action performs that exchange. If you do not use the generated
      # liveviews, you may remove this action, and set
      # `sign_in_tokens_enabled? false` in the password strategy.

      description "Attempt to sign in using a short-lived sign in token."
      get? true

      argument :token, :string do
        description "The short-lived sign in token."
        allow_nil? false
        sensitive? true
      end

      argument :remember_me, :boolean do
        description "Whether to generate a remember me token."
        allow_nil? true
        default false
      end

      # validates the provided sign in token and generates a token
      prepare AshAuthentication.Strategy.Password.SignInWithTokenPreparation
      prepare AshAuthentication.Strategy.RememberMe.MaybeGenerateTokenPreparation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end

      metadata :remember_me, :map do
        description "A map with the remember me token and strategy."
        allow_nil? true
      end
    end

    create :register_with_password do
      description "Register a new user with a email and password."

      argument :email, :ci_string do
        allow_nil? false
      end

      argument :password, :string do
        description "The proposed password for the user, in plain text."
        allow_nil? false
        constraints min_length: 8
        sensitive? true
      end

      argument :password_confirmation, :string do
        description "The proposed password for the user (again), in plain text."
        allow_nil? false
        sensitive? true
      end

      argument :display_name, :string do
        description "Optional display name for the user."
        allow_nil? true
        constraints max_length: 50
      end

      argument :language, :atom do
        description "User's preferred language."
        allow_nil? true
        constraints one_of: [:en, :de]
        default :en
      end

      argument :selected_plan_key, :string do
        description "The plan the user selected during registration (for onboarding flow)."
        allow_nil? true
      end

      argument :name, :string do
        description "User's full name."
        allow_nil? false
        constraints max_length: 100
      end

      argument :accepted_terms, :boolean do
        description "Whether the user accepts Terms of Service and Privacy Policy."
        allow_nil? false
      end

      argument :accepted_age_requirement, :boolean do
        description "Whether the user confirms they are at least 16 years old."
        allow_nil? false
      end

      # Sets the email from the argument
      change set_attribute(:email, arg(:email))

      # Sets optional display_name and language
      change set_attribute(:display_name, arg(:display_name))
      change set_attribute(:language, arg(:language))

      # Sets the selected plan key for onboarding flow
      change set_attribute(:selected_plan_key, arg(:selected_plan_key))

      # Sets name and consent flags
      change set_attribute(:name, arg(:name))
      change set_attribute(:accepted_terms, arg(:accepted_terms))
      change set_attribute(:accepted_age_requirement, arg(:accepted_age_requirement))

      # Prevent timezone gaming: set last_timezone_change_at on registration
      # so users can't immediately change timezone to get extra daily messages
      change set_attribute(:last_timezone_change_at, &DateTime.utc_now/0)

      # Hashes the provided password
      change AshAuthentication.Strategy.Password.HashPasswordChange

      # Generates an authentication token for the user
      change AshAuthentication.GenerateTokenChange

      # validates that the password matches the confirmation
      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation

      validate fn changeset, _context ->
        if Ash.Changeset.get_argument(changeset, :accepted_terms) == true do
          :ok
        else
          {:error, field: :accepted_terms, message: "must be accepted"}
        end
      end

      validate fn changeset, _context ->
        if Ash.Changeset.get_argument(changeset, :accepted_age_requirement) == true do
          :ok
        else
          {:error, field: :accepted_age_requirement, message: "must be accepted"}
        end
      end

      # Create a free subscription for the new user
      change Magus.Accounts.User.Changes.CreateFreeSubscription

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end

    create :admin_create_test_user do
      description """
      Admin-only creation of a workshop/demo test account with a known
      password. Unlike :register_with_password this sends NO emails: the
      action is listed in the confirmation add-on's auto_confirm_actions,
      so the account is confirmed inline and no confirmation/welcome mail
      is dispatched. Consent flags are set to true automatically. Usage
      limits are not handled here — the caller grants an exemption override
      (see Magus.Accounts.TestAccounts).
      """

      argument :email, :ci_string do
        allow_nil? false
      end

      argument :password, :string do
        description "The password for the test account, in plain text."
        allow_nil? false
        constraints min_length: 8
        sensitive? true
      end

      argument :display_name, :string do
        description "Display name (also used as the full name) for the test account."
        allow_nil? false
        constraints max_length: 50
      end

      argument :language, :atom do
        allow_nil? true
        constraints one_of: [:en, :de]
        default :en
      end

      accept [:test_account_expires_at]

      change set_attribute(:email, arg(:email))
      change set_attribute(:display_name, arg(:display_name))
      change set_attribute(:name, arg(:display_name))
      change set_attribute(:language, arg(:language))
      change set_attribute(:test_account, true)
      # Keep the plaintext (encrypted at rest) so an admin can re-show it later.
      change set_attribute(:test_account_password, arg(:password))
      change set_attribute(:accepted_terms, true)
      change set_attribute(:accepted_age_requirement, true)
      change set_attribute(:last_timezone_change_at, &DateTime.utc_now/0)

      # Hash the provided password into hashed_password. No auth token is
      # generated here — participants sign in later through the normal password
      # flow, which mints tokens at sign-in time.
      change {AshAuthentication.Strategy.Password.HashPasswordChange, strategy_name: :password}

      # Put the demo account on the Pay-as-you-go plan (no Stripe) so it can
      # use all models, the auto router, and media generation. Spend limits are
      # additionally waived by the exemption override created by the caller.
      change Magus.Accounts.User.Changes.CreateDemoSubscription
    end

    action :request_password_reset_token do
      description "Send password reset instructions to a user if they exist."

      argument :email, :ci_string do
        allow_nil? false
      end

      # creates a reset token and invokes the relevant senders
      run {AshAuthentication.Strategy.Password.RequestPasswordReset, action: :get_by_email}
    end

    read :get_by_email do
      description "Looks up a user by their email"
      get_by :email

      argument :email, :ci_string, allow_nil?: false
    end

    update :reset_password_with_token do
      argument :reset_token, :string do
        allow_nil? false
        sensitive? true
      end

      argument :password, :string do
        description "The proposed password for the user, in plain text."
        allow_nil? false
        constraints min_length: 8
        sensitive? true
      end

      argument :password_confirmation, :string do
        description "The proposed password for the user (again), in plain text."
        allow_nil? false
        sensitive? true
      end

      # validates the provided reset token
      validate AshAuthentication.Strategy.Password.ResetTokenValidation

      # validates that the password matches the confirmation
      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation

      # Hashes the provided password
      change AshAuthentication.Strategy.Password.HashPasswordChange

      # Generates an authentication token for the user
      change AshAuthentication.GenerateTokenChange
    end

    create :sign_in_with_magic_link do
      description "Sign in or register a user with magic link."

      argument :token, :string do
        description "The token from the magic link that was sent to the user"
        allow_nil? false
      end

      argument :remember_me, :boolean do
        description "Whether to generate a remember me token."
        allow_nil? true
        default true
      end

      upsert? true
      upsert_identity :unique_email
      upsert_fields [:email]

      # Uses the information from the token to create or sign in the user
      change AshAuthentication.Strategy.MagicLink.SignInChange

      # Always generate a remember me token for magic link sign-ins
      change AshAuthentication.Strategy.RememberMe.MaybeGenerateTokenChange

      # Create a free subscription for new users (idempotent - skips if subscription exists)
      change Magus.Accounts.User.Changes.CreateFreeSubscription

      # Set default consent flags (false) for new users — consent is completed post-sign-in
      change Magus.Accounts.User.Changes.SetConsentForNewUser

      metadata :token, :string do
        allow_nil? false
      end

      metadata :remember_me, :map do
        description "A map with the remember me token and strategy."
        allow_nil? true
      end
    end

    action :request_magic_link do
      argument :email, :ci_string do
        allow_nil? false
      end

      run AshAuthentication.Strategy.MagicLink.Request
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    # AshOban triggers (e.g. :consolidate_memories) run without an actor; let them through.
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # Defense in depth for the RPC-exposed self-read: the in-action filter
    # (id == actor.id) already returns nothing for a nil actor, but fail
    # closed regardless of how the broad read policy below evolves.
    policy action(:current_user) do
      authorize_if actor_present()
    end

    # Allow reading users (needed for loading relationships like
    # message.created_by). NEVER expose this bare :read via typescript_rpc —
    # it would make every user row readable; expose narrow actions like
    # :current_user instead.
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:select_workspace) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:select_model) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:select_image_model) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:select_video_model) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:update_image_generation_settings) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:update_video_generation_settings) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:update_profile) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:update_settings) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:update_avatar) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:delete_avatar) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:update_ui_preferences) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:update_global_memory_setting) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:update_timezone) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:complete_profile) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:clear_selected_plan) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:request_email_change) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:confirm_email_change) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:change_password) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:set_password) do
      authorize_if expr(id == ^actor(:id))
    end

    # Bulk-creating workshop/demo test accounts is an admin-only operation.
    policy action(:admin_create_test_user) do
      authorize_if Magus.Checks.IsAdmin
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    attribute :display_name, :string do
      allow_nil? true
      public? true
      constraints max_length: 50
    end

    attribute :hashed_password, :string do
      sensitive? true
    end

    attribute :confirmed_at, :utc_datetime_usec

    attribute :current_workspace_id, :uuid do
      allow_nil? true
      public? true
      description "The user's currently selected workspace"
    end

    attribute :selected_model_id, :uuid do
      allow_nil? true
      public? true
      description "The user's currently selected AI model for chat"
    end

    attribute :selected_image_model_id, :uuid do
      allow_nil? true
      public? true
      description "The user's currently selected AI model for image generation"
    end

    attribute :selected_video_model_id, :uuid do
      allow_nil? true
      public? true
      description "The user's currently selected AI model for video generation"
    end

    attribute :image_generation_settings, :map do
      public? true
      allow_nil? true
      description "Default image generation config (aspect_ratio, image_size)"
    end

    attribute :video_generation_settings, :map do
      public? true
      allow_nil? true

      description "Default video generation config (aspect_ratio, duration, resolution, generate_audio)"
    end

    attribute :is_admin, :boolean do
      default false
      allow_nil? false
      public? true
      description "Admin status - can only be modified via direct database access"
    end

    attribute :language, :atom do
      constraints one_of: [:en, :de]
      default :en
      allow_nil? false
      public? true
      description "User's preferred language"
    end

    attribute :avatar_path, :string do
      allow_nil? true
      public? true
      description "Path to user's avatar image in storage"
    end

    attribute :pending_email, :ci_string do
      allow_nil? true
      public? true
      description "Email address pending confirmation during email change"
    end

    attribute :ui_preferences, :map do
      allow_nil? false
      default %{}
      public? true
      description "User's UI preferences (card open/closed states, etc.)"
    end

    attribute :timezone, :string do
      default "UTC"
      public? true
      description "User's timezone for scheduling and time display"
    end

    attribute :last_timezone_change_at, :utc_datetime_usec do
      allow_nil? true
      public? true

      description "When the user last changed their timezone (rate limited to prevent daily limit exploits)"
    end

    attribute :selected_plan_key, :string do
      allow_nil? true
      public? true

      description "Stores the user's intended plan during registration flow (e.g., 'starter', 'pro')"
    end

    attribute :global_memory_enabled, :boolean do
      default true
      allow_nil? false
      public? true
      description "Whether to include global memories in conversation context"
    end

    attribute :context_strategy, :atom do
      allow_nil? true
      public? true
      constraints one_of: [:rolling, :compact]

      description "Per-user default context strategy; nil inherits the app config default (:rolling)."
    end

    attribute :name, :string do
      allow_nil? true
      public? true
      constraints max_length: 100
      description "User's full name"
    end

    attribute :accepted_terms, :boolean do
      default false
      allow_nil? false
      public? true
      description "Whether the user accepted the Terms of Service and Privacy Policy"
    end

    attribute :accepted_age_requirement, :boolean do
      default false
      allow_nil? false
      public? true
      description "Whether the user confirmed they are at least 16 years old"
    end

    attribute :test_account, :boolean do
      default false
      allow_nil? false
      description "True for workshop/demo accounts created via the admin bulk-create tool."
    end

    attribute :test_account_expires_at, :utc_datetime_usec do
      allow_nil? true

      description "When a test account is auto-deleted by the cleanup worker. nil for normal accounts."
    end

    attribute :test_account_password, Magus.Agents.AgentSecret.EncryptedString do
      allow_nil? true
      sensitive? true

      description "Plaintext password for a test account, encrypted at rest, so an admin can re-show it. Only set for test accounts."
    end

    timestamps()
  end

  relationships do
    belongs_to :current_workspace, Magus.Workspaces.Workspace do
      source_attribute :current_workspace_id
      allow_nil? true
      define_attribute? false
    end

    belongs_to :selected_model, Magus.Chat.Model do
      source_attribute :selected_model_id
      allow_nil? true
    end

    belongs_to :selected_image_model, Magus.Chat.Model do
      source_attribute :selected_image_model_id
      allow_nil? true
    end

    belongs_to :selected_video_model, Magus.Chat.Model do
      source_attribute :selected_video_model_id
      allow_nil? true
    end
  end

  calculations do
    # Whether the user has a password set (vs. magic-link only). Exposes only
    # the boolean, never the hash; lets the settings UI choose between the
    # "change password" and "set password" flows.
    calculate :has_password, :boolean, expr(not is_nil(hashed_password)) do
      public? true
    end

    calculate :avatar_url, :string, Magus.Accounts.User.Calculations.AvatarUrl do
      public? true
      description "Resolved URL for the user's avatar image"
    end

    calculate :name_or_email, :string do
      calculation expr(
                    if not (is_nil(display_name) or display_name == "") do
                      display_name
                    else
                      if not (is_nil(name) or name == "") do
                        name
                      else
                        email
                      end
                    end
                  )
    end
  end

  identities do
    identity :unique_email, [:email]
    identity :unique_display_name, [:display_name]
  end
end
