defmodule Magus.Files.UploadTest do
  use ExUnit.Case, async: true

  alias Magus.Files.Upload

  describe "detect_type/2" do
    test "known MIME types don't need content analysis" do
      assert {:ok, :document} = Upload.detect_type("application/pdf", "anything")
      assert {:ok, :text} = Upload.detect_type("text/plain", "anything")
      assert {:ok, :image} = Upload.detect_type("image/png", <<0, 0, 0>>)
      assert {:ok, :video} = Upload.detect_type("video/mp4", <<0, 0, 0>>)
      assert {:ok, :email} = Upload.detect_type("message/rfc822", "anything")
    end

    test "known MIME type ignores content (binary content with image/ MIME is still :image)" do
      assert {:ok, :image} = Upload.detect_type("image/png", "this is text not a png")
    end

    test "unknown MIME type with text content returns :text" do
      python_code = "def hello():\n    print('hi')\n"
      assert {:ok, :text} = Upload.detect_type("application/octet-stream", python_code)
    end

    test "unknown MIME type with binary content returns error" do
      binary = <<0, 1, 2, 3, 4, 5>>
      assert {:error, _reason} = Upload.detect_type("application/octet-stream", binary)
    end

    test "application/x-python is unknown, detected as text via content" do
      assert {:ok, :text} = Upload.detect_type("application/x-python", "print('hello')")
    end

    test "application/javascript is classified as text" do
      assert {:ok, :text} = Upload.detect_type("application/javascript", "console.log('hi')")
    end

    test "empty MIME type with text content returns :text" do
      assert {:ok, :text} = Upload.detect_type("", "mix phx.server")
    end

    test "nil MIME type with text content returns :text" do
      assert {:ok, :text} = Upload.detect_type(nil, "[package]\nname = \"magus\"\n")
    end

    test "UTF-16 text with octet-stream MIME returns :text" do
      utf16 = :unicode.characters_to_binary("def hello, do: :ok", :utf8, {:utf16, :little})
      content = <<0xFF, 0xFE, utf16::binary>>

      assert {:ok, :text} = Upload.detect_type("application/octet-stream", content)
    end

    test "Latin-1 text with octet-stream MIME returns :text" do
      latin1 = :unicode.characters_to_binary("café = \"mañana\"\n", :utf8, :latin1)
      assert {:ok, :text} = Upload.detect_type("application/octet-stream", latin1)
    end

    # Exercises mime_to_type internally for known document formats
    test "document MIME types" do
      content = "dummy"
      assert {:ok, :document} = Upload.detect_type("application/msword", content)

      assert {:ok, :document} =
               Upload.detect_type(
                 "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                 content
               )

      assert {:ok, :document} =
               Upload.detect_type(
                 "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                 content
               )

      assert {:ok, :document} = Upload.detect_type("application/epub+zip", content)
    end

    test "text/* MIME types" do
      content = "dummy"
      assert {:ok, :text} = Upload.detect_type("text/plain", content)
      assert {:ok, :text} = Upload.detect_type("text/html", content)
      assert {:ok, :text} = Upload.detect_type("text/x-python", content)
      assert {:ok, :text} = Upload.detect_type("application/json", content)
      assert {:ok, :text} = Upload.detect_type("application/xml", content)
    end
  end
end
