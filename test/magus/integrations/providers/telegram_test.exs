defmodule Magus.Integrations.Providers.TelegramTest do
  use ExUnit.Case, async: true

  alias Magus.Integrations.Providers.Telegram

  describe "provider metadata" do
    test "returns correct key" do
      assert Telegram.key() == :telegram
    end

    test "returns correct name" do
      assert Telegram.name() == "Telegram"
    end

    test "returns correct auth type" do
      assert Telegram.auth_type() == :api_key
    end

    test "source type is channel" do
      assert Telegram.source_type() == :channel
    end

    test "defines operations" do
      ops = Telegram.operations()
      assert :send_message in ops
      assert :send_photo in ops
      assert :send_chat_action in ops
      assert :get_me in ops
    end

    test "defines auth fields" do
      fields = Telegram.auth_fields()
      assert length(fields) == 1

      token_field = Enum.find(fields, &(&1.name == :bot_token))
      assert token_field.type == :password
    end
  end

  describe "default configuration" do
    test "defaults to multi conversation mode" do
      assert Telegram.default_conversation_mode() == :multi
    end

    test "defaults to async reply enabled" do
      assert Telegram.default_async_reply_enabled?() == true
    end
  end

  describe "verify_webhook/2" do
    test "returns :ok when secret token matches" do
      integration = %{config: %{"webhook_secret" => "test-secret-123"}}

      conn =
        Plug.Test.conn(:post, "/webhooks/telegram/123")
        |> Plug.Conn.put_req_header("x-telegram-bot-api-secret-token", "test-secret-123")

      assert :ok = Telegram.verify_webhook(conn, integration)
    end

    test "returns :unauthorized when secret token doesn't match" do
      integration = %{config: %{"webhook_secret" => "correct-secret"}}

      conn =
        Plug.Test.conn(:post, "/webhooks/telegram/123")
        |> Plug.Conn.put_req_header("x-telegram-bot-api-secret-token", "wrong-secret")

      assert {:error, :unauthorized} = Telegram.verify_webhook(conn, integration)
    end

    test "returns :unauthorized when header is missing" do
      integration = %{config: %{"webhook_secret" => "test-secret"}}
      conn = Plug.Test.conn(:post, "/webhooks/telegram/123")

      assert {:error, :unauthorized} = Telegram.verify_webhook(conn, integration)
    end

    test "returns :unauthorized when config has no webhook_secret" do
      integration = %{config: %{}}

      conn =
        Plug.Test.conn(:post, "/webhooks/telegram/123")
        |> Plug.Conn.put_req_header("x-telegram-bot-api-secret-token", "some-secret")

      assert {:error, :unauthorized} = Telegram.verify_webhook(conn, integration)
    end
  end

  describe "parse_webhook/2" do
    test "delegates to MessageParser" do
      payload = %{
        "message" => %{
          "message_id" => 1,
          "from" => %{"id" => 100, "first_name" => "Test"},
          "chat" => %{"id" => 100},
          "text" => "Hello"
        }
      }

      assert {:ok, parsed} = Telegram.parse_webhook(payload, [])
      assert parsed.type == :text
      assert parsed.text == "Hello"
    end
  end

  describe "webhook_response/1" do
    test "returns empty 200 response" do
      conn = Plug.Test.conn(:post, "/webhooks/telegram/123")
      conn = Telegram.webhook_response(conn)

      assert conn.status == 200
      assert conn.resp_body == ""
    end
  end

  describe "conversation_identifier/1" do
    test "extracts sender_id as identifier" do
      payload = %{sender_id: "12345"}
      assert {:ok, "12345"} = Telegram.conversation_identifier(payload)
    end

    test "extracts string key sender_id" do
      payload = %{"sender_id" => "67890"}
      assert {:ok, "67890"} = Telegram.conversation_identifier(payload)
    end

    test "returns error when no sender_id" do
      payload = %{text: "Hello"}
      assert {:error, :no_sender_id} = Telegram.conversation_identifier(payload)
    end
  end

  describe "authorize_sender/2" do
    test "returns pending when allowlist and pending are empty (new bot)" do
      integration = %{
        config: %{"allowed_chat_ids" => [], "pending_approvals" => []},
        id: "test-id",
        user_id: "user-id"
      }

      payload = %{chat_id: 12345, sender_name: "Alice", sender_username: "alice"}

      assert {:pending, _msg} = Telegram.authorize_sender(payload, integration)
    end

    test "allows when chat_id is in allowlist" do
      integration = %{
        config: %{"allowed_chat_ids" => ["12345"], "pending_approvals" => []},
        id: "test-id",
        user_id: "user-id"
      }

      payload = %{chat_id: 12345, sender_name: "Alice", sender_username: "alice"}

      assert :ok = Telegram.authorize_sender(payload, integration)
    end

    test "returns pending for unknown sender already in pending" do
      integration = %{
        config: %{
          "allowed_chat_ids" => ["99999"],
          "pending_approvals" => [%{"chat_id" => "12345"}]
        },
        id: "test-id",
        user_id: "user-id"
      }

      payload = %{chat_id: 12345, sender_name: "Alice", sender_username: "alice"}

      assert {:pending, _msg} = Telegram.authorize_sender(payload, integration)
    end
  end

  describe "execute/3" do
    test "returns error for unsupported operation" do
      result = Telegram.execute(:unsupported_op, %{}, %{})
      assert {:error, "Unsupported operation: unsupported_op"} = result
    end

    test "returns error for send_message without chat_id" do
      result = Telegram.execute(:send_message, %{"bot_token" => "tok"}, %{message: "hi"})
      assert {:error, :missing_chat_id_or_text} = result
    end

    test "returns error for send_message without text" do
      result = Telegram.execute(:send_message, %{"bot_token" => "tok"}, %{recipient_id: "123"})
      assert {:error, :missing_chat_id_or_text} = result
    end
  end
end
