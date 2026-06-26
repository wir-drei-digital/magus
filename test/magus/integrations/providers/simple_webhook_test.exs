defmodule Magus.Integrations.Providers.SimpleWebhookTest do
  @moduledoc """
  Tests for the Simple Webhook integration provider.
  """
  use Magus.DataCase, async: true

  alias Magus.Integrations.Providers.SimpleWebhook

  describe "provider metadata" do
    test "returns correct key" do
      assert SimpleWebhook.key() == :simple_webhook
    end

    test "returns correct name" do
      assert SimpleWebhook.name() == "Simple Webhook"
    end

    test "returns correct auth type" do
      assert SimpleWebhook.auth_type() == :webhook_only
    end

    test "source type is channel" do
      assert SimpleWebhook.source_type() == :channel
    end

    test "defines operations" do
      assert :send_message in SimpleWebhook.operations()
    end

    test "defines auth fields" do
      fields = SimpleWebhook.auth_fields()
      assert length(fields) == 2

      api_key_field = Enum.find(fields, &(&1.name == :api_key))
      assert api_key_field.type == :generated

      callback_field = Enum.find(fields, &(&1.name == :callback_url))
      assert callback_field.type == :text
    end
  end

  describe "default configuration" do
    test "defaults to single conversation mode" do
      assert SimpleWebhook.default_conversation_mode() == :single
    end

    test "defaults to async reply enabled" do
      assert SimpleWebhook.default_async_reply_enabled?() == true
    end
  end

  describe "verify_webhook/2" do
    test "returns :ok when API key matches (string credential data)" do
      integration = %{credential: %{encrypted_data: %{"api_key" => "test-secret-key"}}}

      conn =
        Plug.Test.conn(:post, "/webhooks/simple_webhook/123")
        |> Plug.Conn.put_req_header("x-api-key", "test-secret-key")

      assert :ok = SimpleWebhook.verify_webhook(conn, integration)
    end

    test "returns :ok when API key matches (atom credential data)" do
      integration = %{credential: %{encrypted_data: %{api_key: "test-secret-key"}}}

      conn =
        Plug.Test.conn(:post, "/webhooks/simple_webhook/123")
        |> Plug.Conn.put_req_header("x-api-key", "test-secret-key")

      assert :ok = SimpleWebhook.verify_webhook(conn, integration)
    end

    test "returns :unauthorized when API key doesn't match" do
      integration = %{credential: %{encrypted_data: %{"api_key" => "correct-key"}}}

      conn =
        Plug.Test.conn(:post, "/webhooks/simple_webhook/123")
        |> Plug.Conn.put_req_header("x-api-key", "wrong-key")

      assert {:error, :unauthorized} = SimpleWebhook.verify_webhook(conn, integration)
    end

    test "returns :unauthorized when API key header is missing" do
      integration = %{credential: %{encrypted_data: %{"api_key" => "test-key"}}}
      conn = Plug.Test.conn(:post, "/webhooks/simple_webhook/123")

      assert {:error, :unauthorized} = SimpleWebhook.verify_webhook(conn, integration)
    end

    test "returns :unauthorized when credential not present" do
      integration = %{}

      conn =
        Plug.Test.conn(:post, "/webhooks/simple_webhook/123")
        |> Plug.Conn.put_req_header("x-api-key", "some-key")

      assert {:error, :unauthorized} = SimpleWebhook.verify_webhook(conn, integration)
    end

    test "returns :unauthorized when API key not in credential" do
      integration = %{credential: %{encrypted_data: %{}}}

      conn =
        Plug.Test.conn(:post, "/webhooks/simple_webhook/123")
        |> Plug.Conn.put_req_header("x-api-key", "some-key")

      assert {:error, :unauthorized} = SimpleWebhook.verify_webhook(conn, integration)
    end
  end

  describe "parse_webhook/2" do
    test "parses text field" do
      payload = %{"text" => "Hello world"}
      assert {:ok, parsed} = SimpleWebhook.parse_webhook(payload, [])

      assert parsed.type == :text
      assert parsed.text == "Hello world"
      assert parsed.content == "Hello world"
    end

    test "parses message field as text" do
      payload = %{"message" => "Hello from message"}
      assert {:ok, parsed} = SimpleWebhook.parse_webhook(payload, [])

      assert parsed.text == "Hello from message"
    end

    test "parses content field as text" do
      payload = %{"content" => "Hello from content"}
      assert {:ok, parsed} = SimpleWebhook.parse_webhook(payload, [])

      assert parsed.text == "Hello from content"
    end

    test "extracts sender_id" do
      payload = %{"text" => "Hi", "sender_id" => "user-123"}
      assert {:ok, parsed} = SimpleWebhook.parse_webhook(payload, [])

      assert parsed.sender_id == "user-123"
    end

    test "extracts user_id as sender_id" do
      payload = %{"text" => "Hi", "user_id" => "user-456"}
      assert {:ok, parsed} = SimpleWebhook.parse_webhook(payload, [])

      assert parsed.sender_id == "user-456"
    end

    test "extracts external_id from message_id" do
      payload = %{"text" => "Hi", "message_id" => "msg-789"}
      assert {:ok, parsed} = SimpleWebhook.parse_webhook(payload, [])

      assert parsed.external_id == "msg-789"
    end

    test "generates external_id if not provided" do
      payload = %{"text" => "Hi"}
      assert {:ok, parsed} = SimpleWebhook.parse_webhook(payload, [])

      assert is_binary(parsed.external_id)
      assert String.length(parsed.external_id) > 0
    end

    test "extracts metadata" do
      payload = %{"text" => "Hi", "metadata" => %{"key" => "value"}}
      assert {:ok, parsed} = SimpleWebhook.parse_webhook(payload, [])

      assert parsed.metadata == %{"key" => "value"}
    end
  end

  describe "conversation_identifier/1" do
    test "extracts sender_id as identifier" do
      payload = %{sender_id: "user-123"}
      assert {:ok, "user-123"} = SimpleWebhook.conversation_identifier(payload)
    end

    test "extracts string sender_id" do
      payload = %{"sender_id" => "user-456"}
      assert {:ok, "user-456"} = SimpleWebhook.conversation_identifier(payload)
    end

    test "converts integer sender_id to string" do
      payload = %{sender_id: 12345}
      assert {:ok, "12345"} = SimpleWebhook.conversation_identifier(payload)
    end

    test "returns error when no sender_id" do
      payload = %{text: "Hello"}
      assert {:error, :no_sender_id} = SimpleWebhook.conversation_identifier(payload)
    end
  end

  describe "execute/3" do
    test "returns success without callback_url" do
      result = SimpleWebhook.execute(:send_message, %{}, %{message: "Hello"})

      assert {:ok, %{delivered: false, reason: :no_callback_url}} = result
    end

    test "returns success with empty callback_url" do
      result = SimpleWebhook.execute(:send_message, %{}, %{message: "Hello", callback_url: ""})

      assert {:ok, %{delivered: false, reason: :no_callback_url}} = result
    end

    test "returns error for unsupported operation" do
      result = SimpleWebhook.execute(:unsupported_op, %{}, %{})

      assert {:error, "Unsupported operation: unsupported_op"} = result
    end
  end

  describe "generate_api_key/0" do
    test "generates a random key" do
      key1 = SimpleWebhook.generate_api_key()
      key2 = SimpleWebhook.generate_api_key()

      assert is_binary(key1)
      assert is_binary(key2)
      assert key1 != key2
      # Base64 URL-safe encoding of 32 bytes = 43 characters
      assert String.length(key1) == 43
    end
  end
end
