defmodule Magus.Integrations.Reactors.SendReply do
  @moduledoc """
  Orchestrates sending a reply back through an integration provider.

  This reactor:
  1. Loads the user integration with credentials
  2. Validates the reply can be sent
  3. Executes the send operation via the provider
  4. Creates an output message record
  5. Creates an audit log entry

  ## Usage

      Reactor.run(Magus.Integrations.Reactors.SendReply, %{
        user_integration_id: integration.id,
        message: "Hello from the agent!",
        recipient_id: "telegram_chat_id",
        triggered_by_input_id: input_message.id
      })

  ## Inputs

  - `user_integration_id` - UUID of the user integration to send through
  - `message` - The message text to send
  - `recipient_id` - Provider-specific recipient identifier
  - `triggered_by_input_id` - Optional ID of the input message that triggered this reply

  ## Returns

      {:ok, %{output_message_id: uuid, external_id: provider_message_id}}
  """

  use Ash.Reactor

  require Logger

  # =============================================================================
  # Inputs
  # =============================================================================

  input :user_integration_id
  input :message
  input :recipient_id
  input :triggered_by_input_id
  input :operation
  input :photo_data
  input :photo_filename
  input :caption

  # =============================================================================
  # Step 1: Load user integration
  # =============================================================================

  step :integration do
    argument :user_integration_id, input(:user_integration_id)

    run fn args, _context ->
      case Magus.Integrations.get_user_integration(args.user_integration_id,
             authorize?: false
           ) do
        {:ok, integration} -> {:ok, integration}
        {:error, %Ash.Error.Query.NotFound{}} -> {:error, :integration_not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # =============================================================================
  # Step 2: Validate integration can send
  # =============================================================================

  step :validate_can_send do
    argument :integration, result(:integration)

    run fn args, _context ->
      cond do
        args.integration.status != :active ->
          {:error, :integration_not_active}

        not args.integration.async_reply_enabled ->
          {:error, :replies_disabled}

        true ->
          {:ok, :valid}
      end
    end
  end

  # =============================================================================
  # Step 3: Create output message record (pending)
  # =============================================================================

  step :create_output_message do
    argument :integration, result(:integration)
    argument :message, input(:message)
    argument :recipient_id, input(:recipient_id)
    argument :triggered_by_input_id, input(:triggered_by_input_id)
    argument :operation, input(:operation)
    wait_for [:validate_can_send]

    run fn args, _context ->
      op = args.operation || :send_message

      attrs = %{
        user_id: args.integration.user_id,
        user_integration_id: args.integration.id,
        provider_key: args.integration.provider_key,
        operation: op,
        payload: %{
          message: args.message,
          recipient_id: args.recipient_id
        },
        triggered_by_input_id: args.triggered_by_input_id
      }

      case Magus.Integrations.create_output_message(attrs, authorize?: false) do
        {:ok, msg} -> {:ok, msg}
        {:error, reason} -> {:error, {:create_output_failed, reason}}
      end
    end
  end

  # =============================================================================
  # Step 4: Execute send via provider
  # =============================================================================

  step :execute_send do
    argument :integration, result(:integration)
    argument :output_message, result(:create_output_message)
    argument :message, input(:message)
    argument :recipient_id, input(:recipient_id)
    argument :operation, input(:operation)
    argument :photo_data, input(:photo_data)
    argument :photo_filename, input(:photo_filename)
    argument :caption, input(:caption)

    run fn args, _context ->
      start_time = System.monotonic_time()
      op = args.operation || :send_message

      params =
        %{
          message: args.message,
          recipient_id: args.recipient_id
        }
        |> then(fn p ->
          if args.photo_data, do: Map.put(p, :photo_data, args.photo_data), else: p
        end)
        |> then(fn p ->
          if args.photo_filename, do: Map.put(p, :photo_filename, args.photo_filename), else: p
        end)
        |> then(fn p -> if args.caption, do: Map.put(p, :caption, args.caption), else: p end)

      inputs = %{
        user_id: args.integration.user_id,
        provider_key: args.integration.provider_key,
        operation: op,
        params: params
      }

      result = Reactor.run(Magus.Integrations.Reactors.RunIntegration, inputs, async?: false)

      duration = System.monotonic_time() - start_time
      duration_ms = System.convert_time_unit(duration, :native, :millisecond)

      case result do
        {:ok, %{result: response}} ->
          Magus.Integrations.mark_output_sent(
            args.output_message,
            Map.get(response, :external_id),
            authorize?: false
          )

          Magus.Telemetry.integration_operation(
            args.integration.provider_key,
            op,
            duration_ms,
            true
          )

          {:ok, response}

        {:error, reason} ->
          Magus.Integrations.mark_output_failed(args.output_message, authorize?: false)

          Magus.Telemetry.integration_operation(
            args.integration.provider_key,
            op,
            duration_ms,
            false
          )

          {:error, {:send_failed, reason}}
      end
    end
  end

  # =============================================================================
  # Step 5: Create audit log (async)
  # =============================================================================

  step :create_audit_log do
    argument :integration, result(:integration)
    argument :output_message, result(:create_output_message)
    argument :send_result, result(:execute_send)
    argument :operation, input(:operation)
    async? true

    run fn args, _context ->
      Magus.Integrations.record_audit(
        %{
          user_id: args.integration.user_id,
          provider_key: args.integration.provider_key,
          operation: args.operation || :send_message,
          status: :success,
          metadata: %{
            output_message_id: args.output_message.id,
            external_id: Map.get(args.send_result, :external_id)
          }
        },
        authorize?: false
      )

      {:ok, :logged}
    end

    compensate fn _, _, _ -> :ok end
  end

  # =============================================================================
  # Step 6: Build result
  # =============================================================================

  step :build_result do
    argument :output_message, result(:create_output_message)
    argument :send_result, result(:execute_send)
    wait_for [:create_audit_log]

    run fn args, _context ->
      {:ok,
       %{
         output_message_id: args.output_message.id,
         external_id: Map.get(args.send_result, :external_id)
       }}
    end
  end

  # =============================================================================
  # Return
  # =============================================================================

  return :build_result
end
