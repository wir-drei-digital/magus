defmodule Magus.Integrations.Providers.ChannelBehaviour do
  @moduledoc """
  Behaviour for channel integrations that support bidirectional messaging.
  Transport-agnostic — webhook and API channels both implement this.
  """

  @doc "Extract a unique conversation identifier from the parsed input (e.g., sender_id, session_id)."
  @callback conversation_identifier(parsed_input :: map()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "Authorize the sender. Return :ok, {:pending, message}, or {:error, reason}."
  @callback authorize_sender(parsed_input :: map(), integration :: map()) ::
              :ok | {:pending, String.t()} | {:error, term()}

  @doc "Default conversation mode for this channel."
  @callback default_conversation_mode() :: :single | :multi

  @doc "Whether async reply dispatch (via IntegrationReplyPlugin) is enabled by default."
  @callback default_async_reply_enabled?() :: boolean()

  @doc "Extract the message text content from the parsed input."
  @callback extract_message_content(parsed_input :: map()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "Extract the recipient ID from the parsed input for reply routing."
  @callback extract_recipient_id(parsed_input :: map()) ::
              {:ok, String.t() | nil} | {:error, term()}

  @optional_callbacks [
    authorize_sender: 2,
    extract_message_content: 1,
    extract_recipient_id: 1
  ]

  @doc "Default extract_message_content — tries common payload keys."
  def default_extract_message_content(payload) when is_map(payload) do
    content =
      payload["text"] || payload["content"] ||
        payload[:text] || payload[:content]

    case content do
      nil -> {:error, :no_content}
      text -> {:ok, to_string(text)}
    end
  end

  # In direct message contexts (like Telegram DMs), the sender is the reply target,
  # so sender_id is a valid fallback for identifying the recipient.
  @doc "Default extract_recipient_id — tries common payload keys."
  def default_extract_recipient_id(payload) when is_map(payload) do
    recipient =
      payload["sender_id"] || payload["chat_id"] ||
        payload[:sender_id] || payload[:chat_id]

    {:ok, recipient}
  end
end
