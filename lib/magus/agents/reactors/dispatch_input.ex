defmodule Magus.Agents.Reactors.DispatchInput do
  @moduledoc """
  Processes incoming integration messages and routes them to conversations.

  This reactor handles the complete flow from InputMessage creation to
  ConversationAgent processing, without needing a separate InputAgent.

  ## Flow

  1. Loads the InputMessage
  2. Loads the user's integration for this provider
  3. Gets or creates the target conversation (single/multi mode)
  4. Sends the message to the conversation (triggers ConversationAgent)
  5. Marks the input as processed

  ## Conversation Modes

  - **Single mode**: All messages go to one conversation per integration
  - **Multi mode**: Messages routed by external identifier (sender_id)

  ## Usage

      Reactor.run(Magus.Agents.Reactors.DispatchInput, %{
        input_message_id: message.id,
        user_id: message.user_id
      })
  """

  use Ash.Reactor

  require Logger

  alias Magus.Integrations
  alias Magus.Chat

  input :input_message_id
  input :user_id

  # Step 1: Load user
  step :load_user do
    argument :user_id, input(:user_id)

    run fn args, _context ->
      {:ok, Magus.Accounts.get_user!(args.user_id, authorize?: false)}
    end
  end

  # Step 2: Load InputMessage
  step :load_input_message do
    argument :input_message_id, input(:input_message_id)

    run fn args, _context ->
      Integrations.get_input_message(args.input_message_id,
        load: [:user_integration],
        authorize?: false
      )
    end
  end

  # Step 3: Load the integration directly from the InputMessage's FK
  step :load_integration do
    argument :input_message, result(:load_input_message)

    run fn args, _context ->
      case Integrations.get_user_integration(args.input_message.user_integration_id,
             authorize?: false
           ) do
        {:ok, integration} -> {:ok, integration}
        {:error, _} -> {:error, :integration_not_found}
      end
    end
  end

  # Step 4: Check sender authorization (if provider supports it)
  step :authorize_sender do
    argument :input_message, result(:load_input_message)
    argument :integration, result(:load_integration)

    run fn args, _context ->
      provider_module = Integrations.get_provider_module(args.integration.provider_key)

      if provider_module && function_exported?(provider_module, :authorize_sender, 2) do
        case provider_module.authorize_sender(args.input_message.payload, args.integration) do
          :ok ->
            {:ok, :authorized}

          {:pending, msg} ->
            send_pending_response(args.integration, args.input_message.payload, msg)
            {:error, :pending_approval}

          {:error, reason} ->
            {:error, {:sender_denied, reason}}
        end
      else
        {:ok, :authorized}
      end
    end
  end

  # Step 5: Send typing indicator (best-effort, non-blocking)
  step :send_typing_indicator do
    argument :input_message, result(:load_input_message)
    argument :integration, result(:load_integration)
    wait_for [:authorize_sender]

    run fn args, _context ->
      provider = Integrations.get_provider_module(args.integration.provider_key)
      chat_id = extract_recipient_via_provider(provider, args.input_message)

      if chat_id do
        inputs = %{
          user_id: args.integration.user_id,
          provider_key: args.integration.provider_key,
          operation: :send_chat_action,
          params: %{recipient_id: to_string(chat_id), action: "typing"}
        }

        case Reactor.run(Integrations.Reactors.RunIntegration, inputs, async?: false) do
          {:ok, _} -> :ok
          {:error, reason} -> Logger.debug("Typing indicator failed: #{inspect(reason)}")
        end
      end

      {:ok, :sent}
    end
  end

  # Step 6: Get or create conversation
  step :resolve_conversation do
    argument :input_message, result(:load_input_message)
    argument :integration, result(:load_integration)
    argument :user, result(:load_user)
    wait_for [:authorize_sender]

    run fn args, _context ->
      get_or_create_conversation(args.input_message, args.integration, args.user)
    end
  end

  # Step 5: Send message to conversation
  step :send_message do
    argument :input_message, result(:load_input_message)
    argument :integration, result(:load_integration)
    argument :conversation_id, result(:resolve_conversation)
    argument :user, result(:load_user)

    run fn args, _context ->
      input = args.input_message
      provider = Integrations.get_provider_module(args.integration.provider_key)
      text = extract_content_via_provider(provider, input)

      Chat.send_user_message(
        %{
          conversation_id: args.conversation_id,
          text: text,
          metadata: %{
            "source" => "integration",
            "provider_key" => to_string(input.provider_key),
            "input_message_id" => input.id,
            "external_id" => input.external_id
          }
        },
        actor: args.user
      )
    end
  end

  # Step 6: Mark input as processed
  step :mark_processed do
    argument :input_message, result(:load_input_message)
    argument :integration, result(:load_integration)
    argument :conversation_id, result(:resolve_conversation)
    wait_for [:send_message]

    run fn args, _context ->
      input = args.input_message

      case Integrations.mark_input_processed(input, authorize?: false) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to mark input as processed: #{inspect(reason)}")
      end

      # Extract reply_to from payload for multi mode
      reply_to = args.input_message.payload["sender_id"] || args.input_message.payload[:sender_id]

      # Return useful info matching the old ProcessInput.run/2 interface
      {:ok,
       %{
         action: :routed_to_conversation,
         input_id: input.id,
         conversation_id: args.conversation_id,
         provider: input.provider_key,
         reply_enabled: args.integration.async_reply_enabled,
         reply_to: reply_to
       }}
    end
  end

  return :mark_processed

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp send_pending_response(integration, payload, message) do
    chat_id = payload[:chat_id] || payload["chat_id"]

    if chat_id do
      Task.Supervisor.start_child(Magus.Integrations.WebhookTaskSupervisor, fn ->
        inputs = %{
          user_id: integration.user_id,
          provider_key: integration.provider_key,
          operation: :send_message,
          params: %{
            message: message,
            recipient_id: to_string(chat_id)
          }
        }

        case Reactor.run(Integrations.Reactors.RunIntegration, inputs, async?: false) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to send pending response: #{inspect(reason)}")
        end
      end)
    end
  end

  defp get_or_create_conversation(input, integration, user) do
    case integration.conversation_mode do
      :single -> get_or_create_single_conversation(input, integration, user)
      :multi -> get_or_create_multi_conversation(input, integration, user)
    end
  end

  defp get_or_create_single_conversation(input, integration, user) do
    case integration.conversation_id do
      nil ->
        create_and_link_conversation(input, integration, user)

      conversation_id ->
        case Chat.get_conversation(conversation_id, authorize?: false) do
          {:ok, _} -> {:ok, conversation_id}
          {:error, _} -> create_and_link_conversation(input, integration, user)
        end
    end
  end

  defp get_or_create_multi_conversation(input, integration, user) do
    with {:ok, identifier} <- extract_conversation_identifier(input, integration) do
      case Integrations.get_integration_conversation_by_identifier(
             integration.id,
             identifier,
             authorize?: false
           ) do
        {:ok, mapping} ->
          case Chat.get_conversation(mapping.conversation_id, authorize?: false) do
            {:ok, _} -> {:ok, mapping.conversation_id}
            {:error, _} -> create_multi_conversation(input, integration, identifier, user)
          end

        {:error, reason} ->
          if not_found_error?(reason) do
            create_multi_conversation(input, integration, identifier, user)
          else
            {:error, reason}
          end
      end
    end
  end

  defp not_found_error?(%Ash.Error.Query.NotFound{}), do: true

  defp not_found_error?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &not_found_error?/1)

  defp not_found_error?(_), do: false

  defp extract_conversation_identifier(input, integration) do
    provider_module = Integrations.get_provider_module(integration.provider_key)

    cond do
      provider_module && function_exported?(provider_module, :conversation_identifier, 1) ->
        provider_module.conversation_identifier(input.payload)

      input.payload["sender_id"] ->
        {:ok, to_string(input.payload["sender_id"])}

      input.payload[:sender_id] ->
        {:ok, to_string(input.payload[:sender_id])}

      true ->
        {:error, :no_conversation_identifier}
    end
  end

  defp create_and_link_conversation(input, integration, user) do
    with {:ok, conversation} <- create_conversation(input, integration, user),
         {:ok, _} <- link_conversation_to_integration(integration, conversation.id) do
      {:ok, conversation.id}
    end
  end

  defp create_multi_conversation(input, integration, identifier, user) do
    max = get_in(integration.config || %{}, ["max_conversations"])

    if max do
      case Integrations.list_integration_conversations(integration.id, authorize?: false) do
        {:ok, existing} when length(existing) >= max ->
          {:error, :max_conversations_reached}

        _ ->
          do_create_multi_conversation(input, integration, identifier, user)
      end
    else
      do_create_multi_conversation(input, integration, identifier, user)
    end
  end

  defp do_create_multi_conversation(input, integration, identifier, user) do
    with {:ok, conversation} <- create_conversation(input, integration, user),
         {:ok, _} <- create_conversation_mapping(integration.id, conversation.id, identifier) do
      {:ok, conversation.id}
    end
  end

  defp create_conversation(input, integration, user) do
    title = generate_title(input, integration)

    Chat.create_conversation(
      %{title: title, chat_mode: :chat, custom_agent_id: integration.custom_agent_id},
      actor: user
    )
  end

  defp link_conversation_to_integration(integration, conversation_id) do
    Integrations.link_integration_conversation(
      integration,
      %{conversation_id: conversation_id},
      authorize?: false
    )
  end

  defp create_conversation_mapping(user_integration_id, conversation_id, identifier) do
    Integrations.create_integration_conversation(
      %{
        user_integration_id: user_integration_id,
        conversation_id: conversation_id,
        external_identifier: identifier
      },
      authorize?: false
    )
  end

  defp extract_content_via_provider(provider, input) do
    if provider && function_exported?(provider, :extract_message_content, 1) do
      case provider.extract_message_content(input.payload) do
        {:ok, content} -> content
        {:error, _} -> default_extract_content(input)
      end
    else
      default_extract_content(input)
    end
  end

  defp default_extract_content(input) do
    input.payload["text"] ||
      input.payload["content"] ||
      input.payload[:text] ||
      input.payload[:content] ||
      ""
  end

  defp extract_recipient_via_provider(provider, input) do
    if provider && function_exported?(provider, :extract_recipient_id, 1) do
      case provider.extract_recipient_id(input.payload) do
        {:ok, recipient} -> recipient
        {:error, _} -> default_extract_recipient(input)
      end
    else
      default_extract_recipient(input)
    end
  end

  defp default_extract_recipient(input) do
    input.payload["sender_id"] ||
      input.payload["chat_id"] ||
      input.payload[:sender_id] ||
      input.payload[:chat_id]
  end

  defp generate_title(input, integration) do
    provider = Integrations.get_provider_module(integration.provider_key)

    provider_name =
      case provider do
        nil ->
          to_string(integration.provider_key)

        mod when is_atom(mod) ->
          if function_exported?(mod, :name, 0),
            do: mod.name(),
            else: to_string(integration.provider_key)
      end

    content = extract_content_via_provider(provider, input)
    preview = content |> String.slice(0, 40) |> String.trim()

    if String.length(preview) > 0 do
      "#{provider_name}: #{preview}"
    else
      "#{provider_name} conversation"
    end
  end
end
