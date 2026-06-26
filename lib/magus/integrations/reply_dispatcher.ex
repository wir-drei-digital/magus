defmodule Magus.Integrations.ReplyDispatcher do
  @moduledoc """
  Dispatches agent responses back through integration providers.

  Called from the LLM strategy's `finalize_response/3` when a conversation
  was initiated via an integration (e.g., Telegram). Looks up the originating
  integration and sends the reply asynchronously.
  """

  require Logger

  alias Magus.Integrations

  @doc """
  Asynchronously dispatch a reply if the conversation is linked to an integration.

  This is a fire-and-forget operation — failures are logged but don't affect
  the main response flow.
  """
  def maybe_dispatch(conversation_id, response_text, parent_message_id) do
    Task.Supervisor.start_child(Magus.Integrations.WebhookTaskSupervisor, fn ->
      try do
        do_dispatch(conversation_id, response_text, parent_message_id)
      rescue
        e ->
          Logger.error(
            "ReplyDispatcher: exception for conversation #{conversation_id}: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
          )
      end
    end)
  end

  @doc """
  Asynchronously dispatch a reply with image attachments.

  Loads the first image from attachment IDs, reads its content from storage,
  and sends it as a photo with the response text as caption.
  """
  def maybe_dispatch_with_attachments(
        conversation_id,
        response_text,
        attachment_ids,
        parent_message_id
      ) do
    Task.Supervisor.start_child(Magus.Integrations.WebhookTaskSupervisor, fn ->
      try do
        do_dispatch_with_attachments(
          conversation_id,
          response_text,
          attachment_ids,
          parent_message_id
        )
      rescue
        e ->
          Logger.error(
            "ReplyDispatcher: attachment dispatch exception for #{conversation_id}: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
          )
      end
    end)
  end

  defp do_dispatch_with_attachments(
         conversation_id,
         response_text,
         attachment_ids,
         parent_message_id
       ) do
    with {:ok, {recipient_id, integration}} <-
           find_recipient_and_integration(conversation_id, parent_message_id),
         true <- integration.async_reply_enabled do
      case load_first_image(attachment_ids) do
        {:ok, file, file_content} ->
          # Telegram captions are limited to 1024 characters
          caption = if response_text != "", do: String.slice(response_text, 0, 1024)
          filename = Path.basename(file.file_path)

          inputs = %{
            user_integration_id: integration.id,
            message: response_text,
            recipient_id: recipient_id,
            triggered_by_input_id: nil,
            operation: :send_photo,
            photo_data: file_content,
            photo_filename: filename,
            caption: caption
          }

          case Reactor.run(Integrations.Reactors.SendReply, inputs, async?: false) do
            {:ok, _} ->
              # If text exceeds caption limit, send remainder as separate message
              if String.length(response_text) > 1024 do
                remainder = String.slice(response_text, 1024..-1//1)

                remainder_inputs = %{
                  user_integration_id: integration.id,
                  message: remainder,
                  recipient_id: recipient_id,
                  triggered_by_input_id: nil,
                  operation: nil,
                  photo_data: nil,
                  photo_filename: nil,
                  caption: nil
                }

                Reactor.run(Integrations.Reactors.SendReply, remainder_inputs, async?: false)
              end

              Logger.info(
                "ReplyDispatcher: photo reply dispatched to integration #{integration.id}"
              )

            {:error, reason} ->
              Logger.warning("ReplyDispatcher: photo SendReply failed: #{inspect(reason)}")
              # Fall back to text-only
              do_dispatch(conversation_id, response_text, parent_message_id)
          end

        {:error, _reason} ->
          # No image found or failed to load — fall back to text dispatch
          do_dispatch(conversation_id, response_text, parent_message_id)
      end
    else
      false ->
        Logger.info("ReplyDispatcher: async_reply_enabled=false, skipping attachment dispatch")

      {:error, :not_integration_message} ->
        :ok

      {:error, _} ->
        :ok
    end
  end

  defp load_first_image(attachment_ids) when is_list(attachment_ids) and attachment_ids != [] do
    case Magus.Files.get_first_image(attachment_ids, authorize?: false) do
      {:ok, [file | _]} ->
        case Magus.Files.Storage.get(file.file_path) do
          {:ok, content} -> {:ok, file, content}
          {:error, reason} -> {:error, reason}
        end

      {:ok, []} ->
        {:error, :no_images}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_first_image(_), do: {:error, :no_attachments}

  defp do_dispatch(conversation_id, response_text, parent_message_id) do
    Logger.info(
      "ReplyDispatcher: starting dispatch for conversation=#{conversation_id}, parent_msg=#{inspect(parent_message_id)}"
    )

    with {:ok, {recipient_id, integration}} <-
           find_recipient_and_integration(conversation_id, parent_message_id) do
      Logger.info(
        "ReplyDispatcher: found recipient=#{recipient_id}, integration=#{integration.id}, async_reply_enabled=#{integration.async_reply_enabled}"
      )

      if integration.async_reply_enabled do
        inputs = %{
          user_integration_id: integration.id,
          message: response_text,
          recipient_id: recipient_id,
          triggered_by_input_id: nil,
          operation: nil,
          photo_data: nil,
          photo_filename: nil,
          caption: nil
        }

        case Reactor.run(Integrations.Reactors.SendReply, inputs, async?: false) do
          {:ok, _} ->
            Logger.info("ReplyDispatcher: reply dispatched to integration #{integration.id}")

          {:error, reason} ->
            Logger.warning(
              "ReplyDispatcher: SendReply failed for conversation #{conversation_id}: #{inspect(reason)}"
            )
        end
      else
        Logger.info("ReplyDispatcher: async_reply_enabled=false, skipping dispatch")
      end
    else
      {:error, :not_integration_message} ->
        Logger.debug("ReplyDispatcher: not an integration message, skipping")
        :ok

      {:error, :no_integration} ->
        Logger.warning(
          "ReplyDispatcher: no integration found for conversation #{conversation_id}"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "ReplyDispatcher: lookup failed for conversation #{conversation_id}: #{inspect(reason)}"
        )
    end
  end

  # Resolves both the recipient and integration in a single pass to avoid
  # duplicate IntegrationConversation queries.
  defp find_recipient_and_integration(conversation_id, parent_message_id) do
    case find_recipient_from_message(parent_message_id) do
      {:ok, recipient_id} ->
        # We got the recipient from the parent message metadata.
        # Now find the integration.
        case find_integration(conversation_id) do
          {:ok, integration} -> {:ok, {recipient_id, integration}}
          error -> error
        end

      {:error, :not_integration_message} ->
        {:error, :not_integration_message}

      {:error, _} ->
        # Fall back to conversation-level lookup (single query for both)
        find_both_from_conversation(conversation_id)
    end
  end

  defp find_recipient_from_message(nil) do
    Logger.debug("ReplyDispatcher: no parent_message_id provided")
    {:error, :no_parent_message}
  end

  defp find_recipient_from_message(parent_message_id) do
    case Magus.Chat.get_message(parent_message_id, authorize?: false) do
      {:ok, message} ->
        metadata = message.metadata || %{}

        if metadata["source"] == "integration" do
          case metadata["input_message_id"] do
            nil ->
              Logger.warning(
                "ReplyDispatcher: message #{parent_message_id} has source=integration but no input_message_id"
              )

              {:error, :no_input_message}

            input_message_id ->
              case Integrations.get_input_message(input_message_id, authorize?: false) do
                {:ok, input} ->
                  sender_id =
                    input.payload["sender_id"] || input.payload["chat_id"] ||
                      input.payload[:sender_id] || input.payload[:chat_id]

                  if sender_id do
                    {:ok, to_string(sender_id)}
                  else
                    Logger.warning(
                      "ReplyDispatcher: input message #{input_message_id} has no sender_id or chat_id in payload"
                    )

                    {:error, :no_recipient}
                  end

                {:error, _} ->
                  Logger.warning("ReplyDispatcher: input message #{input_message_id} not found")
                  {:error, :input_message_not_found}
              end
          end
        else
          {:error, :not_integration_message}
        end

      {:error, _} ->
        Logger.debug("ReplyDispatcher: parent message #{parent_message_id} not found")
        {:error, :not_integration_message}
    end
  end

  # Single lookup that returns both recipient and integration for multi-mode
  defp find_both_from_conversation(conversation_id) do
    case Integrations.get_integration_conversation_by_conversation_id(
           conversation_id,
           authorize?: false
         ) do
      {:ok, mapping} ->
        Logger.debug(
          "ReplyDispatcher: found conversation mapping, external_identifier=#{mapping.external_identifier}"
        )

        {:ok, {mapping.external_identifier, mapping.user_integration}}

      {:error, _} ->
        Logger.debug(
          "ReplyDispatcher: no conversation mapping found, falling back failed — no integration"
        )

        {:error, :no_integration}
    end
  end

  defp find_integration(conversation_id) do
    # Try multi-mode first
    case Integrations.get_integration_conversation_by_conversation_id(
           conversation_id,
           authorize?: false
         ) do
      {:ok, mapping} ->
        {:ok, mapping.user_integration}

      {:error, _} ->
        # Fall back to single-mode via domain code interface
        case Integrations.get_integration_by_conversation(conversation_id, authorize?: false) do
          {:ok, integration} -> {:ok, integration}
          {:error, _} -> {:error, :no_integration}
        end
    end
  end
end
