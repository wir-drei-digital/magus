defmodule Magus.Integrations.Providers.SimpleWebhook do
  @moduledoc """
  A simple webhook integration for testing and basic integrations.

  This provider allows you to send messages to Magus via a webhook endpoint
  and receive responses. It's ideal for:

  - Testing the integrations system
  - Simple custom integrations
  - Connecting services that just need to send/receive messages

  ## Authentication

  Uses an API key passed in the `X-API-Key` header. The key is stored encrypted
  in the Credential resource for security. Users can generate a new API key from
  the Settings > Integrations page.

  ## Webhook Endpoint

  POST /webhooks/simple_webhook/:user_id

  Headers:
    - X-API-Key: your-api-key (required)
    - Content-Type: application/json

  Body:
    {
      "text": "Your message here",
      "sender_id": "optional-sender-id"  // Required for multi-mode
    }

  Response:
    {
      "status": "received",
      "message_id": "uuid"
    }

  ## Conversation Modes

  - **Single mode**: All messages go to one conversation per integration.
    Good for personal assistants or single-user use cases.

  - **Multi mode**: Uses `sender_id` to route to different conversations.
    Good for bots that serve multiple users.

  ## Reply Handling

  When `async_reply_enabled` is true, the agent response will be sent to a callback
  URL if configured in the integration's config (`callback_url`).
  """

  @behaviour Magus.Integrations.Providers.Behaviour
  @behaviour Magus.Integrations.Providers.ChannelBehaviour
  @behaviour Magus.Integrations.Providers.WebhookChannelBehaviour

  require Logger

  @impl true
  def key, do: :simple_webhook

  @impl true
  def name, do: "Simple Webhook"

  @impl true
  def description do
    "Simple webhook integration for sending and receiving messages via HTTPS"
  end

  @impl true
  def auth_type, do: :webhook_only

  @impl Magus.Integrations.Providers.Behaviour
  def source_type, do: :channel

  @impl true
  def operations, do: [:send_message, :test]

  @impl true
  def auth_fields do
    [
      %{
        name: :api_key,
        label: "API Key",
        type: :generated,
        help: "A secret key to authenticate webhook requests. Click 'Generate' to create one."
      },
      %{
        name: :callback_url,
        label: "Callback URL (optional)",
        type: :text,
        help: "URL to receive agent responses via POST. Leave empty to poll for responses."
      }
    ]
  end

  @impl Magus.Integrations.Providers.ChannelBehaviour
  def default_conversation_mode, do: :single

  @impl Magus.Integrations.Providers.ChannelBehaviour
  def default_async_reply_enabled?, do: true

  @impl Magus.Integrations.Providers.ChannelBehaviour
  def extract_message_content(parsed_input) do
    Magus.Integrations.Providers.ChannelBehaviour.default_extract_message_content(parsed_input)
  end

  @impl Magus.Integrations.Providers.ChannelBehaviour
  def extract_recipient_id(parsed_input) do
    Magus.Integrations.Providers.ChannelBehaviour.default_extract_recipient_id(parsed_input)
  end

  @doc """
  Verify the webhook request using the API key from the Credential resource.

  The API key is passed via the `credential` key in the integration map,
  which is loaded by the WebhookController before calling this function.
  """
  @impl Magus.Integrations.Providers.WebhookChannelBehaviour
  def verify_webhook(conn, integration) do
    # Get API key from credential (encrypted storage) - passed by controller
    expected_key = get_api_key_from_credential(integration)

    case Plug.Conn.get_req_header(conn, "x-api-key") do
      [provided_key] when is_binary(provided_key) ->
        if is_binary(expected_key) and Plug.Crypto.secure_compare(provided_key, expected_key) do
          :ok
        else
          # Return generic error to prevent information leakage
          {:error, :unauthorized}
        end

      [] ->
        # Return same error as invalid key to prevent timing attacks
        {:error, :unauthorized}
    end
  end

  # Extract API key from the credential's encrypted_data
  defp get_api_key_from_credential(%{credential: %{encrypted_data: data}}) when is_map(data) do
    data["api_key"] || data[:api_key]
  end

  defp get_api_key_from_credential(_), do: nil

  @impl Magus.Integrations.Providers.WebhookChannelBehaviour
  def parse_webhook(payload, _headers) do
    text = payload["text"] || payload["message"] || payload["content"]
    sender_id = payload["sender_id"] || payload["user_id"]
    external_id = payload["message_id"] || payload["id"] || Ash.UUIDv7.generate()

    {:ok,
     %{
       type: :text,
       external_id: to_string(external_id),
       text: text,
       content: text,
       sender_id: sender_id && to_string(sender_id),
       metadata: payload["metadata"]
     }}
  end

  @impl Magus.Integrations.Providers.WebhookChannelBehaviour
  def webhook_response(conn) do
    # Return a JSON response with the message ID
    message_id = conn.private[:input_message_id] || Ash.UUIDv7.generate()

    response = %{
      status: "received",
      message_id: message_id
    }

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(response))
  end

  @impl Magus.Integrations.Providers.ChannelBehaviour
  def conversation_identifier(parsed_payload) do
    case parsed_payload[:sender_id] || parsed_payload["sender_id"] do
      nil -> {:error, :no_sender_id}
      sender_id -> {:ok, to_string(sender_id)}
    end
  end

  @impl true
  def execute(:send_message, _credentials, params) do
    # For simple webhook, we don't actually send messages externally
    # The response is returned via the webhook response or a callback URL
    callback_url = params[:callback_url]

    if callback_url && callback_url != "" do
      # Send to callback URL
      body = %{
        message: params[:message] || params[:text],
        conversation_id: params[:conversation_id],
        metadata: params[:metadata]
      }

      case Req.post(callback_url, json: body, receive_timeout: 10_000) do
        {:ok, %{status: status}} when status in 200..299 ->
          {:ok, %{delivered: true, callback_url: callback_url}}

        {:ok, %{status: status, body: body}} ->
          Logger.warning("Callback failed with status #{status}: #{inspect(body)}")
          {:error, "Callback returned status #{status}"}

        {:error, reason} ->
          Logger.warning("Callback request failed: #{inspect(reason)}")
          {:error, "Callback request failed: #{inspect(reason)}"}
      end
    else
      # No callback configured - response will be available via polling
      {:ok, %{delivered: false, reason: :no_callback_url}}
    end
  end

  def execute(:test, _credentials, _params) do
    # Simple test operation - just confirms the integration is configured
    {:ok, %{status: :ok, message: "Webhook integration is configured correctly"}}
  end

  def execute(operation, _credentials, _params) do
    {:error, "Unsupported operation: #{operation}"}
  end

  # Generate a random API key for new integrations
  @doc """
  Generate a secure random API key for use with this integration.
  """
  def generate_api_key do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
