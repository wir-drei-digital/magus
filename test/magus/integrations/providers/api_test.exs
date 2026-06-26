defmodule Magus.Integrations.Providers.ApiTest do
  use Magus.DataCase, async: true

  alias Magus.Integrations.Providers.Api, as: ApiProvider

  describe "behaviour implementation" do
    test "key/0 returns :api" do
      assert ApiProvider.key() == :api
    end

    test "source_type/0 returns :channel" do
      assert ApiProvider.source_type() == :channel
    end

    test "default_conversation_mode/0 returns :multi" do
      assert ApiProvider.default_conversation_mode() == :multi
    end

    test "default_async_reply_enabled?/0 returns false" do
      assert ApiProvider.default_async_reply_enabled?() == false
    end
  end

  describe "parse_request/2" do
    test "parses valid request with content" do
      params = %{"content" => "Hello", "session_id" => "ses_abc123"}
      assert {:ok, parsed} = ApiProvider.parse_request(params, [])
      assert parsed["text"] == "Hello"
      assert parsed["sender_id"] == "ses_abc123"
    end

    test "parses request without session_id — generates one" do
      params = %{"content" => "Hello"}
      assert {:ok, parsed} = ApiProvider.parse_request(params, [])
      assert parsed["text"] == "Hello"
      assert String.starts_with?(parsed["sender_id"], "ses_")
    end

    test "returns error when content is missing" do
      params = %{"session_id" => "ses_abc123"}
      assert {:error, :content_required} = ApiProvider.parse_request(params, [])
    end

    test "includes attachments when present" do
      params = %{
        "content" => "Translate this",
        "attachments" => [%{"type" => "file", "name" => "doc.pdf", "data" => "base64data"}]
      }

      assert {:ok, parsed} = ApiProvider.parse_request(params, [])
      assert length(parsed["attachments"]) == 1
    end
  end

  describe "extract_message_content/1" do
    test "extracts text from parsed input" do
      assert {:ok, "Hello"} = ApiProvider.extract_message_content(%{"text" => "Hello"})
    end

    test "returns error when no text" do
      assert {:error, :no_content} = ApiProvider.extract_message_content(%{})
    end
  end

  describe "extract_recipient_id/1" do
    test "extracts sender_id" do
      assert {:ok, "ses_abc"} = ApiProvider.extract_recipient_id(%{"sender_id" => "ses_abc"})
    end
  end

  describe "conversation_identifier/1" do
    test "returns session_id as conversation identifier" do
      assert {:ok, "ses_abc"} = ApiProvider.conversation_identifier(%{"sender_id" => "ses_abc"})
    end
  end

  describe "authorize_sender/2" do
    test "always returns :ok" do
      assert :ok = ApiProvider.authorize_sender(%{}, %{})
    end
  end

  describe "stream_event_types/1" do
    test "minimal includes only essential events" do
      types = ApiProvider.stream_event_types(:minimal)
      assert "text.chunk" in types
      assert "message.completed" in types
      assert "message.started" in types
      assert "session.created" in types
      assert "error" in types
      refute "tool.started" in types
    end

    test "standard adds tool events" do
      types = ApiProvider.stream_event_types(:standard)
      assert "tool.started" in types
      assert "tool.completed" in types
      refute "tool.progress" in types
      refute "thinking.chunk" in types
    end

    test "full includes everything" do
      types = ApiProvider.stream_event_types(:full)
      assert "tool.progress" in types
      assert "thinking.chunk" in types
    end
  end

  describe "generate_api_key/0" do
    test "generates key with magus_sk_ prefix" do
      key = ApiProvider.generate_api_key()
      assert String.starts_with?(key, "magus_sk_")
      # 9 chars prefix + 32 hex chars
      assert String.length(key) == 9 + 32
    end
  end

  describe "hash_api_key/1" do
    test "returns consistent SHA-256 hash" do
      key = "magus_sk_abc123"
      hash1 = ApiProvider.hash_api_key(key)
      hash2 = ApiProvider.hash_api_key(key)
      assert hash1 == hash2
      assert is_binary(hash1)
      assert String.length(hash1) == 64
    end
  end
end
