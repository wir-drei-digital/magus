defmodule Magus.Integrations.Reactors.RunIntegration do
  @moduledoc """
  Reactor-based executor for integration operations.

  Provides saga-style orchestration with compensation on failure.
  This is the ONLY module that accesses credentials - they are never
  exposed to agent code or other parts of the system.

  ## Usage

      Reactor.run(Magus.Integrations.Reactors.RunIntegration, %{
        user_id: user_id,
        provider_key: :google_calendar,
        operation: :list_events,
        params: %{time_min: DateTime.utc_now() |> DateTime.to_iso8601()}
      })

  ## Security

  - Credentials are loaded internally and never returned
  - All operations are logged to AuditLog
  - Results are sanitized to remove any sensitive data
  - Rate limiting is enforced per user/provider/operation

  ## Flow

  1. Verify user has active integration
  2. Check rate limits
  3. Load credentials (ONLY place credentials are accessed)
  4. Execute provider operation (with automatic token refresh)
  5. Sanitize result to remove sensitive data
  6. Record audit log (async)
  """

  use Ash.Reactor

  require Logger

  alias Magus.Integrations
  alias Magus.Integrations.RateLimiter

  # =============================================================================
  # Inputs
  # =============================================================================

  input :user_id
  input :provider_key
  input :operation
  input :params

  # =============================================================================
  # Step 1: Verify user has active integration
  # =============================================================================

  step :verify_integration do
    argument :user_id, input(:user_id)
    argument :provider_key, input(:provider_key)

    run fn args, _context ->
      case Integrations.list_user_integrations_by_provider(
             args.user_id,
             args.provider_key,
             authorize?: false
           ) do
        {:ok, integrations} ->
          case Enum.find(integrations, &(&1.status == :active)) do
            nil ->
              case integrations do
                [%{status: status} | _] -> {:error, {:integration_not_active, status}}
                [] -> {:error, :integration_not_found}
              end

            integration ->
              {:ok, integration}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # =============================================================================
  # Step 2: Check rate limits
  # =============================================================================

  step :check_rate_limit do
    argument :user_id, input(:user_id)
    argument :provider_key, input(:provider_key)
    argument :operation, input(:operation)

    run fn args, _context ->
      case RateLimiter.check(args.user_id, args.provider_key, args.operation) do
        :ok -> {:ok, :allowed}
        {:error, reason} -> {:error, {:rate_limited, reason}}
      end
    end
  end

  # =============================================================================
  # Step 3: Load credentials (ONLY place credentials are accessed)
  # =============================================================================

  step :load_credentials do
    argument :integration, result(:verify_integration)
    wait_for [:check_rate_limit]

    run fn args, _context ->
      case Integrations.get_credential_for_integration(args.integration.id, authorize?: false) do
        {:ok, credential} ->
          {:ok, %{credentials: credential.encrypted_data, credential_record: credential}}

        {:error, %Ash.Error.Query.NotFound{}} ->
          {:error, :credentials_not_found}

        {:error, _} ->
          {:error, :credentials_not_found}
      end
    end
  end

  # =============================================================================
  # Step 4: Execute provider operation (with automatic token refresh)
  # =============================================================================

  step :execute_operation do
    argument :provider_key, input(:provider_key)
    argument :operation, input(:operation)
    argument :params, input(:params)
    argument :integration, result(:verify_integration)
    argument :credential_data, result(:load_credentials)

    run fn args, _context ->
      started_at = System.monotonic_time(:millisecond)
      credentials = args.credential_data.credentials

      result =
        case do_execute(args.provider_key, args.operation, credentials, args.params) do
          {:error, :token_expired} ->
            # Attempt to refresh the token and retry
            refresh_and_retry(
              args.provider_key,
              args.operation,
              credentials,
              args.params,
              args.integration,
              args.credential_data.credential_record
            )

          other ->
            other
        end

      duration = System.monotonic_time(:millisecond) - started_at

      case result do
        {:ok, raw_result} ->
          {:ok, %{result: raw_result, duration_ms: duration, success: true}}

        {:error, reason} ->
          {:ok, %{error: reason, duration_ms: duration, success: false}}
      end
    end
  end

  # =============================================================================
  # Step 5: Sanitize result
  # =============================================================================

  step :sanitize_result do
    argument :execution, result(:execute_operation)

    run fn args, _context ->
      if args.execution.success do
        {:ok, %{result: sanitize(args.execution.result), duration_ms: args.execution.duration_ms}}
      else
        {:error, args.execution.error}
      end
    end
  end

  # =============================================================================
  # Step 6: Record audit log (async, non-blocking)
  # =============================================================================

  step :record_audit do
    argument :user_id, input(:user_id)
    argument :provider_key, input(:provider_key)
    argument :operation, input(:operation)
    argument :execution, result(:execute_operation)
    async? true

    run fn args, _context ->
      {status, error_details} =
        if args.execution.success do
          {:success, nil}
        else
          {:failure, inspect(args.execution.error)}
        end

      try do
        Integrations.record_audit(
          %{
            user_id: args.user_id,
            provider_key: args.provider_key,
            operation: to_string(args.operation),
            status: status,
            error_details: error_details,
            metadata: %{duration_ms: args.execution.duration_ms}
          },
          authorize?: false
        )

        {:ok, :logged}
      rescue
        e ->
          Logger.warning("Failed to record audit log: #{inspect(e)}")
          {:ok, :log_failed}
      end
    end

    compensate fn _, _, _ -> :ok end
  end

  # =============================================================================
  # Return
  # =============================================================================

  return :sanitize_result

  # =============================================================================
  # Private Helper Functions
  # =============================================================================

  defp do_execute(provider_key, operation, credentials, params) do
    provider = Integrations.get_provider_module(provider_key)

    if provider do
      try do
        provider.execute(operation, credentials, params)
      rescue
        e ->
          Logger.error("Integration operation failed: #{inspect(e)}")
          {:error, {:execution_error, Exception.message(e)}}
      end
    else
      {:error, {:unknown_provider, provider_key}}
    end
  end

  defp refresh_and_retry(
         provider_key,
         operation,
         credentials,
         params,
         integration,
         credential_record
       ) do
    provider = Integrations.get_provider_module(provider_key)

    if provider && function_exported?(provider, :refresh_token, 1) do
      case provider.refresh_token(credentials) do
        {:ok, new_credentials} ->
          # Store the refreshed credentials
          case store_refreshed_credentials(credential_record, new_credentials) do
            {:ok, _} ->
              # Retry the operation with new credentials
              do_execute(provider_key, operation, new_credentials, params)

            {:error, reason} ->
              Logger.error("Failed to store refreshed credentials: #{inspect(reason)}")
              {:error, :token_refresh_failed}
          end

        {:error, :refresh_token_revoked} ->
          Logger.warning("Refresh token revoked for integration #{integration.id}")
          {:error, :reauthorization_required}

        {:error, reason} ->
          Logger.error("Token refresh failed: #{inspect(reason)}")
          {:error, :token_refresh_failed}
      end
    else
      # Provider doesn't support token refresh
      {:error, :token_expired}
    end
  end

  defp store_refreshed_credentials(credential_record, new_credentials) do
    expires_at = parse_expiry(new_credentials["expires_at"])

    Integrations.refresh_credential(
      credential_record,
      %{encrypted_data: new_credentials, expires_at: expires_at},
      authorize?: false
    )
  end

  defp parse_expiry(nil), do: nil

  defp parse_expiry(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_expiry(_), do: nil

  # Sanitize result to remove sensitive data
  defp sanitize(result) when is_map(result) do
    sensitive_keys = [
      :access_token,
      :refresh_token,
      :api_key,
      :password,
      :secret,
      :token,
      :credentials,
      :bot_token
    ]

    result
    |> Map.drop(sensitive_keys)
    |> Enum.map(fn
      {k, v} when is_map(v) -> {k, sanitize(v)}
      {k, v} when is_list(v) -> {k, Enum.map(v, &sanitize_value/1)}
      pair -> pair
    end)
    |> Map.new()
  end

  defp sanitize(result), do: result

  defp sanitize_value(v) when is_map(v), do: sanitize(v)
  defp sanitize_value(v), do: v
end
