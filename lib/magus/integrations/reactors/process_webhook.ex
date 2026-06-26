defmodule Magus.Integrations.Reactors.ProcessWebhook do
  @moduledoc """
  Processes an incoming webhook after verification.

  This reactor handles the business logic of webhook processing:
  1. Parses the webhook payload (provider-specific)
  2. Creates an InputMessage record (which triggers DispatchInput)
  3. Creates an audit log entry

  The controller handles Plug.Conn-specific concerns:
  - Loading integration with credentials
  - Webhook verification (needs conn)
  - Rate limiting
  - Sending provider-specific response (needs conn)

  ## Usage

      Reactor.run(Magus.Integrations.Reactors.ProcessWebhook, %{
        user_id: user_id,
        provider_key: :simple_webhook,
        integration_id: integration.id,
        payload: %{"text" => "Hello"},
        headers: conn.req_headers,
        ip_address: "1.2.3.4"
      })

  ## Inputs

  - `user_id` - UUID of the user who owns the integration
  - `provider_key` - The provider atom (e.g., :telegram, :simple_webhook)
  - `integration_id` - UUID of the UserIntegration
  - `payload` - The raw webhook payload (map)
  - `headers` - Request headers (list of tuples)
  - `ip_address` - Client IP address for audit logging

  ## Returns

      {:ok, %{input_message_id: uuid, external_id: string}}
  """

  use Ash.Reactor

  require Logger

  alias Magus.Integrations

  input :user_id
  input :provider_key
  input :integration_id
  input :payload
  input :headers
  input :ip_address

  # Step 1: Parse webhook payload using provider
  step :parse_payload do
    argument :payload, input(:payload)
    argument :headers, input(:headers)
    argument :provider_key, input(:provider_key)

    run fn args, _context ->
      provider = Integrations.get_provider_module(args.provider_key)

      if provider && function_exported?(provider, :parse_webhook, 2) do
        case provider.parse_webhook(args.payload, args.headers) do
          {:ok, parsed} ->
            {:ok, parsed}

          {:error, reason} ->
            Logger.warning("Webhook parsing failed for #{args.provider_key}: #{inspect(reason)}")
            {:error, {:parse_failed, reason}}
        end
      else
        # No parsing needed, use payload as-is
        {:ok, %{type: :raw, payload: args.payload}}
      end
    end
  end

  # Step 2: Create InputMessage record
  # This triggers the SignalInputAgent change which runs DispatchInput
  step :create_input_message do
    argument :user_id, input(:user_id)
    argument :provider_key, input(:provider_key)
    argument :integration_id, input(:integration_id)
    argument :parsed, result(:parse_payload)
    argument :raw_payload, input(:payload)

    run fn args, _context ->
      attrs = %{
        user_id: args.user_id,
        user_integration_id: args.integration_id,
        provider_key: args.provider_key,
        external_id: args.parsed[:external_id],
        message_type: args.parsed[:type] || :text,
        payload: args.parsed,
        raw_payload: args.raw_payload
      }

      case Integrations.create_input_message(attrs, authorize?: false) do
        {:ok, msg} ->
          {:ok, msg}

        {:error, %Ash.Error.Invalid{errors: errors} = reason} ->
          if Enum.any?(errors, fn
               %{private_vars: pvars} when is_list(pvars) ->
                 Keyword.get(pvars, :constraint_type) == :unique

               _ ->
                 false
             end) do
            {:error, :duplicate_message}
          else
            {:error, {:create_input_failed, reason}}
          end

        {:error, reason} ->
          {:error, {:create_input_failed, reason}}
      end
    end
  end

  # Step 3: Create audit log (async, non-blocking)
  step :create_audit_log do
    argument :user_id, input(:user_id)
    argument :provider_key, input(:provider_key)
    argument :ip_address, input(:ip_address)
    argument :input_message, result(:create_input_message)
    async? true

    run fn args, _context ->
      Integrations.record_audit(
        %{
          user_id: args.user_id,
          provider_key: args.provider_key,
          operation: "webhook_received",
          status: :success,
          ip_address: args.ip_address,
          metadata: %{input_message_id: args.input_message.id}
        },
        authorize?: false
      )

      {:ok, :logged}
    end

    compensate fn _, _, _ -> :ok end
  end

  # Step 4: Build result
  step :build_result do
    argument :input_message, result(:create_input_message)
    argument :parsed, result(:parse_payload)
    wait_for [:create_audit_log]

    run fn args, _context ->
      {:ok,
       %{
         input_message_id: args.input_message.id,
         external_id: args.parsed[:external_id] || args.input_message.id
       }}
    end
  end

  return :build_result
end
