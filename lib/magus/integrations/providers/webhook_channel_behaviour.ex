defmodule Magus.Integrations.Providers.WebhookChannelBehaviour do
  @moduledoc """
  Behaviour for webhook-based channel integrations (e.g., Telegram, SimpleWebhook).
  Extends ChannelBehaviour with HTTP webhook-specific callbacks.
  """

  @doc "Verify the webhook request authenticity using the Plug.Conn and integration config."
  @callback verify_webhook(conn :: Plug.Conn.t(), integration :: map()) ::
              :ok | {:error, atom()}

  @doc "Parse the raw webhook payload and headers into a normalized map."
  @callback parse_webhook(payload :: map(), headers :: list()) ::
              {:ok, map()} | {:error, term()}

  @doc "Send a provider-specific HTTP response to acknowledge the webhook."
  @callback webhook_response(conn :: Plug.Conn.t()) :: Plug.Conn.t()

  @optional_callbacks [webhook_response: 1]
end
