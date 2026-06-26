defmodule Mix.Tasks.Magus.TestWebhook do
  @moduledoc """
  Send a test message via the Simple Webhook integration.

  This task simulates an incoming webhook request to test the integration flow.

  ## Usage

      mix magus.test_webhook --user-id <user_id> --api-key <api_key> --text "Hello!"

  ## Options

    * `--user-id` - The user ID who owns the integration (required)
    * `--api-key` - The API key configured for the integration (required)
    * `--text` - The message text to send (required)
    * `--sender-id` - Optional sender ID for multi-mode routing
    * `--host` - The host to send to (default: http://localhost:4000)

  ## Examples

      # Send a simple message
      mix magus.test_webhook --user-id abc123 --api-key mykey --text "Hello from CLI"

      # Send with sender ID for multi-mode
      mix magus.test_webhook --user-id abc123 --api-key mykey --text "Hi" --sender-id user456

      # Send to production
      mix magus.test_webhook --user-id abc123 --api-key mykey --text "Hi" --host https://app.example.com

  """

  use Mix.Task

  @shortdoc "Send a test message via Simple Webhook integration"

  @switches [
    user_id: :string,
    api_key: :string,
    text: :string,
    sender_id: :string,
    host: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    user_id = opts[:user_id]
    api_key = opts[:api_key]
    text = opts[:text]
    sender_id = opts[:sender_id]
    host = opts[:host] || "http://localhost:4000"

    cond do
      is_nil(user_id) ->
        Mix.shell().error("Missing required option: --user-id")
        print_usage()
        exit({:shutdown, 1})

      is_nil(api_key) ->
        Mix.shell().error("Missing required option: --api-key")
        print_usage()
        exit({:shutdown, 1})

      is_nil(text) ->
        Mix.shell().error("Missing required option: --text")
        print_usage()
        exit({:shutdown, 1})

      true ->
        send_webhook(host, user_id, api_key, text, sender_id)
    end
  end

  defp send_webhook(host, user_id, api_key, text, sender_id) do
    # Start the app to ensure Req is available
    Mix.Task.run("app.start")

    url = "#{host}/webhooks/simple_webhook/#{user_id}"

    body =
      %{
        text: text,
        message_id: Ash.UUIDv7.generate()
      }
      |> maybe_add_sender_id(sender_id)

    headers = [
      {"content-type", "application/json"},
      {"x-api-key", api_key}
    ]

    Mix.shell().info("""
    Sending webhook request:
      URL: #{url}
      Text: #{text}
      Sender ID: #{sender_id || "(none)"}
    """)

    case Req.post(url, json: body, headers: headers, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: response_body}} ->
        Mix.shell().info("""

        Success! Response:
          Status: received
          Message ID: #{response_body["message_id"]}
        """)

      {:ok, %{status: status, body: body}} ->
        Mix.shell().error("""

        Request failed with status #{status}:
          #{inspect(body)}
        """)

        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("""

        Request failed:
          #{inspect(reason)}

        Make sure the server is running (mix phx.server)
        """)

        exit({:shutdown, 1})
    end
  end

  defp maybe_add_sender_id(body, nil), do: body
  defp maybe_add_sender_id(body, sender_id), do: Map.put(body, :sender_id, sender_id)

  defp print_usage do
    Mix.shell().info("""

    Usage: mix magus.test_webhook --user-id <id> --api-key <key> --text "message"

    Options:
      --user-id     User ID who owns the integration (required)
      --api-key     API key for authentication (required)
      --text        Message text to send (required)
      --sender-id   Sender ID for multi-mode routing (optional)
      --host        Server host (default: http://localhost:4000)

    Example:
      mix magus.test_webhook --user-id abc123 --api-key mykey --text "Hello!"
    """)
  end
end
