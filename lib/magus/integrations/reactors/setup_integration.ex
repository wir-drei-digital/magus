defmodule Magus.Integrations.Reactors.SetupIntegration do
  @moduledoc """
  Orchestrates the setup of a new integration after OAuth completion or API key entry.

  This reactor:
  1. Creates or updates the user integration record
  2. Stores encrypted credentials
  3. Calls provider-specific post-setup hooks (e.g., webhook registration)
  4. Activates the integration

  ## Usage

      Reactor.run(Magus.Integrations.Reactors.SetupIntegration, %{
        user_id: user.id,
        custom_agent_id: agent.id,
        provider_key: :telegram,
        credentials: %{bot_token: "123:ABC..."},
        config: %{webhook_secret: "secret123"}
      })

  ## Inputs

  - `user_id` - UUID of the user setting up the integration
  - `custom_agent_id` - UUID of the agent this integration is bound to
  - `provider_key` - The provider atom (e.g., :telegram, :google_calendar)
  - `credentials` - Map of credentials to store (will be encrypted)
  - `config` - Optional provider-specific configuration

  ## Returns

      {:ok, %Magus.Integrations.UserIntegration{}}
  """

  use Ash.Reactor

  require Logger

  # =============================================================================
  # Inputs
  # =============================================================================

  input :user_id
  input :custom_agent_id
  input :provider_key
  input :credentials
  input :config

  # =============================================================================
  # Step 1: Validate provider key
  # =============================================================================

  step :validate_provider do
    argument :provider_key, input(:provider_key)

    run fn args, _context ->
      case Magus.Integrations.get_provider_module(args.provider_key) do
        nil -> {:error, :provider_module_not_found}
        module -> {:ok, module}
      end
    end
  end

  # =============================================================================
  # Step 2: Create or update user integration
  # =============================================================================

  step :upsert_integration do
    argument :user_id, input(:user_id)
    argument :custom_agent_id, input(:custom_agent_id)
    argument :provider_key, input(:provider_key)
    argument :config, input(:config)
    wait_for [:validate_provider]

    run fn args, _context ->
      # Check if this agent already has an integration for this provider
      case Magus.Integrations.get_agent_integration_by_provider(
             args.custom_agent_id,
             args.provider_key,
             authorize?: false
           ) do
        {:ok, existing} ->
          Magus.Integrations.update_integration_config(
            existing,
            %{config: args.config || %{}},
            authorize?: false
          )

        {:error, reason} ->
          if not_found_error?(reason) do
            Magus.Integrations.create_user_integration(
              args.provider_key,
              %{
                user_id: args.user_id,
                custom_agent_id: args.custom_agent_id,
                config: args.config || %{}
              },
              authorize?: false
            )
          else
            {:error, reason}
          end
      end
    end
  end

  # =============================================================================
  # Step 3: Store encrypted credentials
  # =============================================================================

  step :store_credentials do
    argument :integration, result(:upsert_integration)
    argument :credentials, input(:credentials)
    argument :provider_module, result(:validate_provider)

    run fn args, _context ->
      credential_type =
        case args.provider_module.auth_type() do
          :oauth2 -> :oauth2
          :api_key -> :api_key
          :imap -> :imap
          _ -> :api_key
        end

      case Magus.Integrations.create_credential(
             %{
               user_integration_id: args.integration.id,
               credential_type: credential_type,
               encrypted_data: args.credentials
             },
             authorize?: false
           ) do
        {:ok, credential} -> {:ok, credential}
        {:error, reason} -> {:error, {:credential_store_failed, reason}}
      end
    end
  end

  # =============================================================================
  # Step 4: Call provider post-setup hook
  # =============================================================================

  step :post_setup_hook do
    argument :integration, result(:upsert_integration)
    argument :credentials, input(:credentials)
    argument :provider_key, input(:provider_key)
    wait_for [:store_credentials]

    run fn args, _context ->
      provider = Magus.Integrations.get_provider_module(args.provider_key)

      if function_exported?(provider, :on_credentials_saved, 2) do
        case provider.on_credentials_saved(args.integration, args.credentials) do
          {:ok, result} ->
            Logger.debug("Post-setup hook completed for #{args.provider_key}: #{inspect(result)}")
            {:ok, result}

          {:error, reason} ->
            Logger.warning("Post-setup hook failed for #{args.provider_key}: #{inspect(reason)}")
            # Don't fail the whole setup, just log
            {:ok, %{hook_error: reason}}
        end
      else
        {:ok, :no_hook}
      end
    end
  end

  # =============================================================================
  # Step 5: Activate the integration
  # =============================================================================

  step :activate do
    argument :integration, result(:upsert_integration)
    wait_for [:post_setup_hook]

    run fn args, _context ->
      Magus.Integrations.activate_user_integration(args.integration, authorize?: false)
    end
  end

  # =============================================================================
  # Step 6: Create audit log
  # =============================================================================

  step :create_audit_log do
    argument :user_id, input(:user_id)
    argument :provider_key, input(:provider_key)
    argument :integration, result(:activate)
    async? true

    run fn args, _context ->
      Magus.Integrations.record_audit(
        %{
          user_id: args.user_id,
          provider_key: args.provider_key,
          operation: :setup_integration,
          status: :success,
          metadata: %{
            integration_id: args.integration.id
          }
        },
        authorize?: false
      )

      {:ok, :logged}
    end

    compensate fn _, _, _ -> :ok end
  end

  # =============================================================================
  # Return
  # =============================================================================

  return :activate

  defp not_found_error?(%Ash.Error.Query.NotFound{}), do: true

  defp not_found_error?(%{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &not_found_error?/1)
  end

  defp not_found_error?(%{error: error}), do: not_found_error?(error)
  defp not_found_error?(_), do: false
end
