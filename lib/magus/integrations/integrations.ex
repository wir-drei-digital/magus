defmodule Magus.Integrations do
  @moduledoc """
  Domain for external service integrations.

  Provides a plugin-based system for connecting to external services like
  Telegram, Google Calendar, Discord, Slack, etc.

  Key features:
  - **Secure Credential Storage**: Encrypted at rest using Cloak (AES-256-GCM)
  - **Generic Provider System**: Add new integrations by implementing the Provider behaviour
  - **Rate Limiting**: Per-user, per-provider rate limiting
  - **Audit Logging**: All credential access is logged
  - **Webhook Support**: Generic webhook infrastructure with provider-specific verification

  Security Architecture:
  - Credentials are encrypted and NEVER exposed to agent code
  - Only the Executor module can access credentials via internal bypass
  - All operations are logged to AuditLog for security auditing
  """

  use Ash.Domain, otp_app: :magus, extensions: [AshTypescript.Rpc]

  typescript_rpc do
    resource Magus.Integrations.UserIntegration do
      rpc_action :list_user_integrations, :for_user
      rpc_action :update_integration_config, :update_config
    end
  end

  resources do
    resource Magus.Integrations.UserIntegration do
      define :create_user_integration, action: :create, args: [:provider_key]
      define :get_user_integration, action: :read, get_by: [:id]

      define :list_user_integrations_by_provider,
        action: :by_user_and_provider,
        args: [:user_id, :provider_key]

      define :list_user_integrations, action: :for_user, args: [:user_id]
      define :list_agent_integrations, action: :for_agent, args: [:custom_agent_id]

      define :get_agent_integration_by_provider,
        action: :by_agent_and_provider,
        args: [:custom_agent_id, :provider_key]

      define :activate_user_integration, action: :activate
      define :deactivate_user_integration, action: :deactivate
      define :update_integration_config, action: :update_config
      define :link_integration_conversation, action: :link_conversation
      define :update_integration_enabled_tools, action: :update_enabled_tools

      define :get_integration_by_conversation,
        action: :by_conversation,
        args: [:conversation_id]

      define :record_integration_sync, action: :record_sync

      define :list_by_agent_and_provider,
        action: :list_by_agent_and_provider,
        args: [:custom_agent_id, :provider_key]
    end

    resource Magus.Integrations.Credential do
      # Internal read - only used by Executor/Reactors with authorize?: false
      define :get_credential_for_integration,
        action: :for_integration,
        args: [:user_integration_id]

      define :get_credential_by_key_hash, action: :by_key_hash, args: [:key_hash], get?: true

      define :create_credential, action: :create
      define :refresh_credential, action: :refresh_token
      define :revoke_credential, action: :destroy
    end

    resource Magus.Integrations.InputMessage do
      define :create_input_message, action: :create
      define :get_input_message, action: :read, get_by: [:id]
      define :list_pending_input_messages, action: :pending
      define :list_recent_input_messages, action: :recent, args: [:user_id]
      define :mark_input_processed, action: :mark_processed
      define :mark_input_failed, action: :mark_failed
      define :count_pending_input_messages, action: :count_pending, args: [:user_id]
      define :count_processed_today, action: :count_processed_today, args: [:user_id]
    end

    resource Magus.Integrations.OutputMessage do
      define :create_output_message, action: :create
      define :get_output_message, action: :read, get_by: [:id]
      define :list_recent_output_messages, action: :recent, args: [:user_id]
      define :mark_output_sent, action: :mark_sent
      define :mark_output_failed, action: :mark_failed
      define :count_messages_today, action: :count_today, args: [:user_integration_id]
    end

    resource Magus.Integrations.AuditLog do
      define :record_audit, action: :record
      define :list_audit_logs, action: :read
      define :list_audit_logs_for_user, action: :for_user, args: [:user_id]
    end

    resource Magus.Integrations.IntegrationConversation do
      define :create_integration_conversation, action: :create

      define :get_integration_conversation_by_identifier,
        action: :by_identifier,
        args: [:user_integration_id, :external_identifier]

      define :list_integration_conversations,
        action: :for_integration,
        args: [:user_integration_id]

      define :get_integration_conversation_by_conversation_id,
        action: :by_conversation_id,
        args: [:conversation_id]

      define :destroy_integration_conversation, action: :destroy
    end

    resource Magus.Integrations.IngestionEntry do
      define :create_ingestion_entry, action: :create
      define :list_ingestion_entries, action: :for_integration, args: [:user_integration_id]
      define :list_user_ingestion_entries, action: :for_user_sources, args: [:user_id]

      define :list_ingestion_entries_by_severity,
        action: :count_by_severity,
        args: [:user_integration_id, :severity, :since]
    end
  end

  @doc """
  Get the provider module for a given key.

  Backed by `Magus.Integrations.Registry` (built-in providers plus any runtime
  registrations), so cloud/external code can add providers without editing core.
  """
  def get_provider_module(key) when is_atom(key) do
    Magus.Integrations.Registry.get(key)
  end

  def get_provider_module(key) when is_binary(key) do
    get_provider_module(String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  @doc """
  List all registered provider modules.
  """
  def list_provider_modules do
    Magus.Integrations.Registry.all()
  end

  @doc """
  List all available providers with metadata derived from modules.
  Replaces the DB-backed Provider resource for UI and runtime queries.
  """
  def list_available_providers do
    Magus.Integrations.Registry.all()
    |> Enum.map(fn {key, module} ->
      %{
        key: key,
        name: module.name(),
        description: module.description(),
        auth_type: module.auth_type(),
        source_type: module.source_type(),
        has_tools: function_exported?(module, :tools, 0),
        requires_admin?:
          function_exported?(module, :requires_admin?, 0) and module.requires_admin?(),
        auth_fields:
          if(function_exported?(module, :auth_fields, 0), do: module.auth_fields(), else: []),
        oauth_config:
          if(function_exported?(module, :oauth_config, 0), do: module.oauth_config(), else: nil)
      }
    end)
  end

  @doc """
  Check if a provider requires admin privileges.

  Accepts either an integration provider key (e.g. `:google_drive_knowledge`)
  or a knowledge connector key (e.g. `:google_drive`). Returns `false` if the
  provider doesn't implement the optional `requires_admin?/0` callback.
  """
  def requires_admin?(provider_key) when is_atom(provider_key) do
    # Try direct lookup first, then with _knowledge suffix
    module =
      get_provider_module(provider_key) ||
        get_provider_module(:"#{provider_key}_knowledge")

    module != nil and
      function_exported?(module, :requires_admin?, 0) and
      module.requires_admin?()
  end

  @doc """
  Returns the auth help map for a provider, or `nil` if not defined.

  Accepts either an integration provider key or a knowledge connector key.
  """
  def auth_help(provider_key) when is_atom(provider_key) do
    module =
      get_provider_module(provider_key) ||
        get_provider_module(:"#{provider_key}_knowledge")

    if module != nil and function_exported?(module, :auth_help, 0) do
      module.auth_help()
    end
  end

  def list_available_providers(source_type) when is_atom(source_type) do
    list_available_providers()
    |> Enum.filter(&(&1.source_type == source_type))
  end

  @doc """
  Load decrypted credentials for an integration.

  This is the primary entry point for any code that needs credentials —
  Oban workers, sync jobs, etc. Credentials are decrypted transparently
  by the EncryptedMap Ash type.

  Returns `{:ok, decrypted_map}` or `{:error, :credentials_not_found}`.
  """
  def load_credentials(integration_id) do
    case get_credential_for_integration(integration_id, authorize?: false) do
      {:ok, credential} ->
        {:ok, credential.encrypted_data}

      {:error, %Ash.Error.Query.NotFound{}} ->
        {:error, :credentials_not_found}

      {:error, _} ->
        {:error, :credentials_not_found}
    end
  end

  @doc """
  Count ingestion entries for a given integration, severity, and time window.
  """
  def count_ingestion_entries_by_severity(integration_id, severity, since, opts \\ []) do
    require Ash.Query

    Magus.Integrations.IngestionEntry
    |> Ash.Query.for_read(:count_by_severity, %{
      user_integration_id: integration_id,
      severity: severity,
      since: since
    })
    |> Ash.count(opts)
  end

  @doc """
  Get all enabled tools for a specific agent across its active integrations.

  Same as `get_enabled_tools_for_user/2` but scoped to a single agent.
  """
  def get_enabled_tools_for_agent(custom_agent_id, opts \\ []) do
    with {:ok, integrations} <- list_agent_integrations(custom_agent_id, opts) do
      tools =
        integrations
        |> Enum.filter(&(&1.status == :active))
        |> Enum.flat_map(&get_enabled_tools_for_integration/1)

      {:ok, tools}
    end
  end

  @doc """
  Get enabled tool modules for a specific integration.
  """
  def get_enabled_tools_for_integration(integration) do
    provider_module = get_provider_module(integration.provider_key)

    if provider_module && function_exported?(provider_module, :tools, 0) do
      all_tools = provider_module.tools()
      enabled_keys = integration.enabled_tools || []

      all_tools
      |> Enum.filter(fn tool -> tool.key in enabled_keys end)
      |> Enum.map(fn tool -> tool.module end)
    else
      []
    end
  end

  @doc """
  Get all available tools for a provider (for displaying in settings UI).
  """
  def get_available_tools_for_provider(provider_key) do
    provider_module = get_provider_module(provider_key)

    if provider_module && function_exported?(provider_module, :tools, 0) do
      provider_module.tools()
    else
      []
    end
  end
end
