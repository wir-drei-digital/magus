defmodule Magus.Integrations.Providers.Telegram do
  @moduledoc """
  Telegram Bot integration provider.

  Allows users to chat with their Magus AI assistant through a Telegram bot.
  Uses the Telegram Bot API for sending/receiving messages.

  ## Setup Flow

  1. User creates a bot via @BotFather on Telegram
  2. User pastes the bot token in Settings > Integrations
  3. On save: we validate the token (getMe), register a webhook, and store config
  4. Incoming messages are verified via secret_token header
  5. New senders are held in pending_approvals until the user approves them

  ## Sender Authorization

  Telegram bots are public by default — anyone can message them. We use an
  allowlist (`allowed_chat_ids`) to restrict who can interact. Unknown senders
  are added to `pending_approvals` and receive a one-time notice.
  """

  @behaviour Magus.Integrations.Providers.Behaviour
  @behaviour Magus.Integrations.Providers.ChannelBehaviour
  @behaviour Magus.Integrations.Providers.WebhookChannelBehaviour

  require Logger

  alias Magus.Integrations.Providers.Telegram.Api
  alias Magus.Integrations.Providers.Telegram.Formatter
  alias Magus.Integrations.Providers.Telegram.MessageParser

  @impl true
  def key, do: :telegram

  @impl true
  def name, do: "Telegram"

  @impl true
  def description, do: "Send and receive messages via Telegram bot"

  @impl true
  def auth_type, do: :api_key

  @impl Magus.Integrations.Providers.Behaviour
  def source_type, do: :channel

  @impl true
  def operations, do: [:send_message, :send_photo, :send_chat_action, :get_me]

  @impl true
  def auth_fields do
    [
      %{
        name: :bot_token,
        label: "Bot Token",
        type: :password,
        help: "Get this from @BotFather on Telegram"
      }
    ]
  end

  @impl true
  def auth_help do
    %{
      text: """
      1. Open Telegram and search for @BotFather
      2. Send /newbot and follow the prompts to create your bot
      3. Copy the bot token provided by BotFather and paste it above
      4. After connecting, each new user who messages your bot will appear here as a pending approval.
      """,
      url: "https://core.telegram.org/bots/tutorial",
      url_label: "Telegram Bot Tutorial"
    }
  end

  @impl Magus.Integrations.Providers.ChannelBehaviour
  def default_conversation_mode, do: :multi

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

  # ===========================================================================
  # Webhook Handling
  # ===========================================================================

  @impl Magus.Integrations.Providers.WebhookChannelBehaviour
  def verify_webhook(conn, integration) do
    expected_secret = get_in(integration, [Access.key(:config), Access.key("webhook_secret")])

    case Plug.Conn.get_req_header(conn, "x-telegram-bot-api-secret-token") do
      [provided] when is_binary(provided) and is_binary(expected_secret) ->
        if Plug.Crypto.secure_compare(provided, expected_secret) do
          :ok
        else
          {:error, :unauthorized}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  @impl Magus.Integrations.Providers.WebhookChannelBehaviour
  def parse_webhook(payload, _headers) do
    MessageParser.parse(payload)
  end

  @impl Magus.Integrations.Providers.WebhookChannelBehaviour
  def webhook_response(conn) do
    Plug.Conn.send_resp(conn, 200, "")
  end

  @impl Magus.Integrations.Providers.ChannelBehaviour
  def conversation_identifier(parsed_payload) do
    case parsed_payload[:sender_id] || parsed_payload["sender_id"] do
      nil -> {:error, :no_sender_id}
      sender_id -> {:ok, to_string(sender_id)}
    end
  end

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  @impl true
  def on_credentials_saved(integration, credentials) do
    token = credentials["bot_token"] || credentials[:bot_token]

    with {:ok, bot_info} <- Api.get_me(token) do
      webhook_secret = generate_webhook_secret()
      webhook_url = build_webhook_url(integration)

      webhook_result =
        if localhost?(webhook_url) do
          Logger.info(
            "Skipping Telegram webhook registration on localhost — use mix magus.test_telegram to test"
          )

          {:ok, :skipped}
        else
          Api.set_webhook(token, webhook_url, secret_token: webhook_secret)
        end

      case webhook_result do
        {:ok, _} ->
          config = %{
            "webhook_secret" => webhook_secret,
            "bot_username" => bot_info["username"],
            "bot_first_name" => bot_info["first_name"],
            "allowed_chat_ids" => [],
            "pending_approvals" => []
          }

          case update_integration_config(integration, config) do
            {:ok, _} ->
              {:ok, config}

            {:error, reason} ->
              Logger.error("Failed to persist Telegram config: #{inspect(reason)}")
              {:error, {:config_update_failed, reason}}
          end

        {:error, reason} ->
          Logger.error("Failed to set Telegram webhook: #{inspect(reason)}")
          {:error, {:webhook_setup_failed, reason}}
      end
    end
  end

  @impl true
  def on_credentials_removed(_integration, credentials) do
    token = credentials["bot_token"] || credentials[:bot_token]

    if token do
      case Api.delete_webhook(token) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to delete Telegram webhook: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  # ===========================================================================
  # Execute Operations
  # ===========================================================================

  @impl true
  def execute(:get_me, credentials, _params) do
    token = credentials["bot_token"] || credentials[:bot_token]
    Api.get_me(token)
  end

  def execute(:send_message, credentials, params) do
    token = credentials["bot_token"] || credentials[:bot_token]

    chat_id =
      params[:recipient_id] || params[:chat_id] || params["recipient_id"] || params["chat_id"]

    text = params[:message] || params[:text] || params["message"] || params["text"]

    if chat_id && text do
      html = Formatter.to_telegram_html(text)
      Api.send_message(token, chat_id, html, parse_mode: "HTML")
    else
      {:error, :missing_chat_id_or_text}
    end
  end

  def execute(:send_photo, credentials, params) do
    token = credentials["bot_token"] || credentials[:bot_token]

    chat_id =
      params[:recipient_id] || params[:chat_id] || params["recipient_id"] || params["chat_id"]

    photo = params[:photo] || params["photo"]
    photo_data = params[:photo_data] || params["photo_data"]
    photo_filename = params[:photo_filename] || params["photo_filename"] || "photo.jpg"

    caption = params[:caption] || params["caption"]

    caption_opts =
      if caption, do: [caption: Formatter.to_telegram_html(caption), parse_mode: "HTML"], else: []

    cond do
      chat_id && photo_data ->
        Api.send_photo(token, chat_id, {:binary, photo_data, photo_filename}, caption_opts)

      chat_id && photo ->
        Api.send_photo(token, chat_id, photo, caption_opts)

      true ->
        {:error, :missing_chat_id_or_photo}
    end
  end

  def execute(:send_chat_action, credentials, params) do
    token = credentials["bot_token"] || credentials[:bot_token]

    chat_id =
      params[:recipient_id] || params[:chat_id] || params["recipient_id"] || params["chat_id"]

    action = params[:action] || params["action"] || "typing"

    if chat_id do
      Api.send_chat_action(token, chat_id, action)
    else
      {:error, :missing_chat_id}
    end
  end

  def execute(operation, _credentials, _params) do
    {:error, "Unsupported operation: #{operation}"}
  end

  # ===========================================================================
  # Sender Authorization
  # ===========================================================================

  @doc """
  Check if a sender is authorized to use this bot.

  Returns:
  - `:ok` if the chat_id is in the allowlist
  - `{:pending, message}` if the sender is new and was added to pending_approvals
  - `{:error, reason}` on failure
  """
  @impl Magus.Integrations.Providers.ChannelBehaviour
  def authorize_sender(parsed_payload, integration) do
    chat_id = parsed_payload[:chat_id] || parsed_payload["chat_id"]
    chat_id_str = to_string(chat_id)

    config = integration.config || %{}
    allowed = config["allowed_chat_ids"] || []
    pending = config["pending_approvals"] || []

    cond do
      chat_id_str in Enum.map(allowed, &to_string/1) ->
        :ok

      already_pending?(pending, chat_id_str) ->
        {:pending, "Your access request is still pending approval."}

      true ->
        add_to_pending(integration, parsed_payload, chat_id_str)
        {:pending, "Your message has been received. Access is pending approval by the bot owner."}
    end
  end

  # ===========================================================================
  # Private
  # ===========================================================================

  defp generate_webhook_secret do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp build_webhook_url(integration) do
    base_url = Magus.Endpoint.url()
    "#{base_url}/webhooks/telegram/#{integration.id}"
  end

  defp localhost?(url) do
    uri = URI.parse(url)
    uri.host in ["localhost", "127.0.0.1", "0.0.0.0"]
  end

  defp update_integration_config(integration, config) do
    Magus.Integrations.update_integration_config(
      integration,
      %{config: Map.merge(integration.config || %{}, config)},
      authorize?: false
    )
  end

  defp already_pending?(pending, chat_id_str) do
    Enum.any?(pending, fn entry ->
      to_string(entry["chat_id"] || entry[:chat_id]) == chat_id_str
    end)
  end

  defp add_to_pending(integration, parsed_payload, chat_id_str) do
    config = integration.config || %{}
    pending = config["pending_approvals"] || []

    sender_name = parsed_payload[:sender_name] || "Unknown"

    new_entry = %{
      "chat_id" => chat_id_str,
      "sender_name" => sender_name,
      "sender_username" => parsed_payload[:sender_username],
      "requested_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    new_config = Map.put(config, "pending_approvals", pending ++ [new_entry])

    case Magus.Integrations.update_integration_config(
           integration,
           %{config: new_config},
           authorize?: false
         ) do
      {:ok, updated} ->
        # Notify the bot owner about the new access request
        Magus.Notifications.create_notification(
          %{
            user_id: integration.user_id,
            title: "Telegram: New access request",
            body: "#{sender_name} wants to chat with your bot",
            notification_type: :approval_request,
            metadata: %{"navigate_to" => "/settings/integrations"}
          },
          authorize?: false
        )

        {:ok, updated}

      error ->
        error
    end
  end
end
