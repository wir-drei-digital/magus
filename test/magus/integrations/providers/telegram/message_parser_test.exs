defmodule Magus.Integrations.Providers.Telegram.MessageParserTest do
  use ExUnit.Case, async: true

  alias Magus.Integrations.Providers.Telegram.MessageParser

  describe "parse/1 - text messages" do
    test "parses a simple text message" do
      payload = %{
        "update_id" => 123,
        "message" => %{
          "message_id" => 456,
          "from" => %{
            "id" => 789,
            "first_name" => "John",
            "last_name" => "Doe",
            "username" => "johndoe"
          },
          "chat" => %{"id" => 789, "type" => "private"},
          "text" => "Hello bot!"
        }
      }

      assert {:ok, parsed} = MessageParser.parse(payload)
      assert parsed.type == :text
      assert parsed.external_id == "456"
      assert parsed.text == "Hello bot!"
      assert parsed.content == "Hello bot!"
      assert parsed.sender_id == "789"
      assert parsed.sender_name == "John Doe"
      assert parsed.sender_username == "johndoe"
      assert parsed.chat_id == 789
      assert parsed.metadata == %{}
    end

    test "handles message with first name only" do
      payload = %{
        "message" => %{
          "message_id" => 1,
          "from" => %{"id" => 100, "first_name" => "Alice"},
          "chat" => %{"id" => 100},
          "text" => "Hi"
        }
      }

      assert {:ok, parsed} = MessageParser.parse(payload)
      assert parsed.sender_name == "Alice"
      assert parsed.sender_username == nil
    end
  end

  describe "parse/1 - photo messages" do
    test "picks the largest photo" do
      payload = %{
        "message" => %{
          "message_id" => 2,
          "from" => %{"id" => 100, "first_name" => "Alice"},
          "chat" => %{"id" => 100},
          "photo" => [
            %{"file_id" => "small", "file_unique_id" => "s1", "width" => 90, "height" => 90},
            %{"file_id" => "medium", "file_unique_id" => "m1", "width" => 320, "height" => 320},
            %{"file_id" => "large", "file_unique_id" => "l1", "width" => 800, "height" => 800}
          ],
          "caption" => "Check this out"
        }
      }

      assert {:ok, parsed} = MessageParser.parse(payload)
      assert parsed.type == :image
      assert parsed.text == "Check this out"
      assert parsed.metadata.file_id == "large"
      assert parsed.metadata.width == 800
    end

    test "handles photo without caption" do
      payload = %{
        "message" => %{
          "message_id" => 3,
          "from" => %{"id" => 100, "first_name" => "Alice"},
          "chat" => %{"id" => 100},
          "photo" => [
            %{"file_id" => "photo1", "file_unique_id" => "u1", "width" => 200, "height" => 200}
          ]
        }
      }

      assert {:ok, parsed} = MessageParser.parse(payload)
      assert parsed.type == :image
      assert parsed.text == ""
    end
  end

  describe "parse/1 - document messages" do
    test "parses a document" do
      payload = %{
        "message" => %{
          "message_id" => 4,
          "from" => %{"id" => 100, "first_name" => "Alice"},
          "chat" => %{"id" => 100},
          "document" => %{
            "file_id" => "doc1",
            "file_name" => "report.pdf",
            "mime_type" => "application/pdf",
            "file_size" => 12345
          },
          "caption" => "Here is the report"
        }
      }

      assert {:ok, parsed} = MessageParser.parse(payload)
      assert parsed.type == :file
      assert parsed.text == "Here is the report"
      assert parsed.metadata.file_id == "doc1"
      assert parsed.metadata.file_name == "report.pdf"
      assert parsed.metadata.mime_type == "application/pdf"
    end
  end

  describe "parse/1 - audio messages" do
    test "parses an audio message" do
      payload = %{
        "message" => %{
          "message_id" => 5,
          "from" => %{"id" => 100, "first_name" => "Alice"},
          "chat" => %{"id" => 100},
          "audio" => %{
            "file_id" => "audio1",
            "duration" => 180,
            "title" => "Song",
            "performer" => "Artist"
          }
        }
      }

      assert {:ok, parsed} = MessageParser.parse(payload)
      assert parsed.type == :audio
      assert parsed.metadata.file_id == "audio1"
      assert parsed.metadata.duration == 180
    end

    test "parses a voice message" do
      payload = %{
        "message" => %{
          "message_id" => 6,
          "from" => %{"id" => 100, "first_name" => "Alice"},
          "chat" => %{"id" => 100},
          "voice" => %{"file_id" => "voice1", "duration" => 5}
        }
      }

      assert {:ok, parsed} = MessageParser.parse(payload)
      assert parsed.type == :audio
      assert parsed.metadata.file_id == "voice1"
    end
  end

  describe "parse/1 - video messages" do
    test "parses a video" do
      payload = %{
        "message" => %{
          "message_id" => 7,
          "from" => %{"id" => 100, "first_name" => "Alice"},
          "chat" => %{"id" => 100},
          "video" => %{
            "file_id" => "vid1",
            "duration" => 30,
            "width" => 1920,
            "height" => 1080
          },
          "caption" => "My video"
        }
      }

      assert {:ok, parsed} = MessageParser.parse(payload)
      assert parsed.type == :video
      assert parsed.text == "My video"
      assert parsed.metadata.file_id == "vid1"
    end
  end

  describe "parse/1 - sticker messages" do
    test "parses a sticker" do
      payload = %{
        "message" => %{
          "message_id" => 8,
          "from" => %{"id" => 100, "first_name" => "Alice"},
          "chat" => %{"id" => 100},
          "sticker" => %{
            "file_id" => "sticker1",
            "emoji" => "thumbs_up",
            "set_name" => "MyPack"
          }
        }
      }

      assert {:ok, parsed} = MessageParser.parse(payload)
      assert parsed.type == :image
      assert parsed.text == "thumbs_up"
      assert parsed.metadata.is_sticker == true
      assert parsed.metadata.set_name == "MyPack"
    end
  end

  describe "parse/1 - location messages" do
    test "parses a location" do
      payload = %{
        "message" => %{
          "message_id" => 9,
          "from" => %{"id" => 100, "first_name" => "Alice"},
          "chat" => %{"id" => 100},
          "location" => %{"latitude" => 48.8584, "longitude" => 2.2945}
        }
      }

      assert {:ok, parsed} = MessageParser.parse(payload)
      assert parsed.type == :event
      assert parsed.text == "Location shared"
      assert parsed.metadata.latitude == 48.8584
      assert parsed.metadata.longitude == 2.2945
    end
  end

  describe "parse/1 - callback queries" do
    test "parses a callback query" do
      payload = %{
        "update_id" => 999,
        "callback_query" => %{
          "id" => "cb123",
          "from" => %{"id" => 100, "first_name" => "Alice", "username" => "alice"},
          "message" => %{"message_id" => 50, "chat" => %{"id" => 100}},
          "data" => "action:confirm"
        }
      }

      assert {:ok, parsed} = MessageParser.parse(payload)
      assert parsed.type == :callback
      assert parsed.external_id == "cb123"
      assert parsed.text == "action:confirm"
      assert parsed.sender_id == "100"
      assert parsed.chat_id == 100
      assert parsed.metadata.callback_query_id == "cb123"
    end
  end

  describe "parse/1 - edited messages" do
    test "parses an edited message" do
      payload = %{
        "edited_message" => %{
          "message_id" => 10,
          "from" => %{"id" => 100, "first_name" => "Alice"},
          "chat" => %{"id" => 100},
          "text" => "Edited text"
        }
      }

      assert {:ok, parsed} = MessageParser.parse(payload)
      assert parsed.type == :text
      assert parsed.text == "Edited text"
    end
  end

  describe "parse/1 - unsupported" do
    test "returns error for unsupported update type" do
      payload = %{"update_id" => 123}

      assert {:error, :unsupported_update_type} = MessageParser.parse(payload)
    end
  end
end
