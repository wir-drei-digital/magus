defmodule Mix.Tasks.Magus.TestTelegram do
  @moduledoc """
  Simulate a Telegram webhook message to test the integration locally.

  This task builds a realistic Telegram Update payload and POSTs it to your
  local webhook endpoint, including the correct secret token header. The
  webhook secret is read from the database automatically.

  Requires the Phoenix server to be running (`mix phx.server`).

  ## Usage

      mix magus.test_telegram --user-id <user_id> --text "Hello!"

  ## Options

    * `--user-id`   - The user ID who owns the Telegram integration (required)
    * `--text`      - The message text to send (default: "Hello from test!")
    * `--chat-id`   - Telegram chat ID of the simulated sender (default: 123456789)
    * `--sender`    - Sender first name (default: "TestUser")
    * `--username`  - Sender username (default: "testuser")
    * `--host`      - Server host (default: http://localhost:4000)

  ## Examples

      # Minimal — send a test message
      mix magus.test_telegram --user-id abc123

      # Custom message and sender
      mix magus.test_telegram --user-id abc123 --text "Hi bot!" --sender "Daniel" --chat-id 999

  """

  use Mix.Task

  @shortdoc "Simulate a Telegram webhook message for local testing"

  @switches [
    user_id: :string,
    text: :string,
    chat_id: :integer,
    sender: :string,
    username: :string,
    host: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    user_id = opts[:user_id]

    if is_nil(user_id) do
      Mix.shell().error("Missing required option: --user-id")
      print_usage()
      exit({:shutdown, 1})
    end

    Mix.Task.run("app.start")

    text = opts[:text] || "Hello from test!"
    chat_id = opts[:chat_id] || 123_456_789
    sender = opts[:sender] || "TestUser"
    username = opts[:username] || "testuser"
    host = opts[:host] || "http://localhost:4000"

    case load_telegram_integration(user_id) do
      {:ok, integration, secret} ->
        send_telegram_webhook(host, integration.id, secret, %{
          text: text,
          chat_id: chat_id,
          sender: sender,
          username: username
        })

      {:error, reason} ->
        Mix.shell().error("Failed to load integration: #{reason}")
        exit({:shutdown, 1})
    end
  end

  defp load_telegram_integration(user_id) do
    case Magus.Integrations.list_user_integrations_by_provider(
           user_id,
           :telegram,
           authorize?: false
         ) do
      {:ok, integrations} ->
        case Enum.find(integrations, &(&1.status == :active)) do
          nil ->
            {:error, "No active Telegram integration found for user #{user_id}"}

          %{config: config} = integration ->
            case config["webhook_secret"] do
              nil -> {:error, "No webhook_secret in integration config. Re-save your bot token."}
              secret -> {:ok, integration, secret}
            end
        end

      {:error, _} ->
        {:error, "No Telegram integration found for user #{user_id}"}
    end
  end

  defp send_telegram_webhook(host, integration_id, secret, params) do
    url = "#{host}/webhooks/telegram/#{integration_id}"
    message_id = :rand.uniform(999_999)

    payload = %{
      "update_id" => :rand.uniform(999_999_999),
      "message" => %{
        "message_id" => message_id,
        "from" => %{
          "id" => params.chat_id,
          "is_bot" => false,
          "first_name" => params.sender,
          "username" => params.username,
          "language_code" => "en"
        },
        "chat" => %{
          "id" => params.chat_id,
          "first_name" => params.sender,
          "username" => params.username,
          "type" => "private"
        },
        "date" => DateTime.utc_now() |> DateTime.to_unix(),
        "text" => params.text
      }
    }

    headers = [
      {"content-type", "application/json"},
      {"x-telegram-bot-api-secret-token", secret}
    ]

    Mix.shell().info("""
    Sending simulated Telegram webhook:
      URL:       #{url}
      Text:      #{params.text}
      Chat ID:   #{params.chat_id}
      Sender:    #{params.sender} (@#{params.username})
    """)

    case Req.post(url, json: payload, headers: headers, receive_timeout: 30_000) do
      {:ok, %{status: 200}} ->
        Mix.shell().info("Success! Webhook accepted (200 OK)")

      {:ok, %{status: status, body: body}} ->
        Mix.shell().error("Failed with status #{status}: #{inspect(body)}")
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("""
        Request failed: #{inspect(reason)}

        Make sure the server is running (mix phx.server)
        """)

        exit({:shutdown, 1})
    end
  end

  defp print_usage do
    Mix.shell().info("""

    Usage: mix magus.test_telegram --user-id <id> [--text "message"]

    Options:
      --user-id     User ID who owns the integration (required)
      --text        Message text (default: "Hello from test!")
      --chat-id     Simulated Telegram chat ID (default: 123456789)
      --sender      Sender first name (default: "TestUser")
      --username    Sender Telegram username (default: "testuser")
      --host        Server host (default: http://localhost:4000)
    """)
  end
end
