defmodule Magus.Files.FileAnalyzerTest do
  use ExUnit.Case, async: true

  alias Magus.Files.FileAnalyzer

  describe "text?/1" do
    test "empty binary is text" do
      assert FileAnalyzer.text?(<<>>)
    end

    test "UTF-8 BOM is text" do
      assert FileAnalyzer.text?(<<0xEF, 0xBB, 0xBF, "hello">>)
    end

    test "UTF-16 LE BOM is text" do
      utf16 = :unicode.characters_to_binary("hello", :utf8, {:utf16, :little})
      assert FileAnalyzer.text?(<<0xFF, 0xFE, utf16::binary>>)
    end

    test "UTF-16 BE BOM is text" do
      utf16 = :unicode.characters_to_binary("hello", :utf8, {:utf16, :big})
      assert FileAnalyzer.text?(<<0xFE, 0xFF, utf16::binary>>)
    end

    test "plain ASCII text is text" do
      assert FileAnalyzer.text?("Hello, world!\nThis is a test.")
    end

    test "Python source code is text" do
      content = """
      def hello():
          print("Hello, world!")

      if __name__ == "__main__":
          hello()
      """

      assert FileAnalyzer.text?(content)
    end

    test "C++ source code is text" do
      content = """
      #include <iostream>

      int main() {
          std::cout << "Hello, world!" << std::endl;
          return 0;
      }
      """

      assert FileAnalyzer.text?(content)
    end

    test "JSON content is text" do
      assert FileAnalyzer.text?(~s({"key": "value", "number": 42}))
    end

    test "HTML content is text" do
      assert FileAnalyzer.text?("<html><body><h1>Hello</h1></body></html>")
    end

    test "Latin-1 text is detected as text" do
      latin1 = :unicode.characters_to_binary("café mañana", :utf8, :latin1)
      assert FileAnalyzer.text?(latin1)
    end

    test "binary with null bytes is not text" do
      assert not FileAnalyzer.text?(<<0, 1, 2, 3, 4>>)
    end

    test "binary with embedded null byte is not text" do
      assert not FileAnalyzer.text?("hello\0world")
    end

    test "PNG header is not text" do
      # PNG magic bytes
      assert not FileAnalyzer.text?(<<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0>>)
    end

    test "PDF header is not text" do
      # PDF files contain null bytes in their structure
      assert not FileAnalyzer.text?("%PDF-1.4\n1 0 obj\n<<\n>>\n" <> <<0, 0, 0>>)
    end

    test "only checks first 1024 bytes" do
      # Text in first 1024 bytes, null byte after — should be detected as text
      text_part = String.duplicate("a", 1025)
      content = text_part <> <<0>>
      assert FileAnalyzer.text?(content)
    end

    test "null byte within first 1024 bytes detected" do
      text_part = String.duplicate("a", 500)
      content = text_part <> <<0>> <> String.duplicate("b", 600)
      assert not FileAnalyzer.text?(content)
    end

    test "null byte at last position in 1024-byte chunk is detected" do
      text_part = String.duplicate("a", 1023)
      content = text_part <> <<0>> <> String.duplicate("b", 100)
      assert not FileAnalyzer.text?(content)
    end

    test "invalid control-heavy binary without null bytes is not text" do
      assert not FileAnalyzer.text?(<<1, 2, 3, 195, 4, 5, 6, 7, 8, 11, 12, 14, 15, 16>>)
    end
  end

  describe "to_utf8/1" do
    test "returns UTF-8 text unchanged" do
      assert {:ok, "hello"} = FileAnalyzer.to_utf8("hello")
    end

    test "decodes UTF-16 LE with BOM to UTF-8" do
      utf16 = :unicode.characters_to_binary("hello", :utf8, {:utf16, :little})
      assert {:ok, "hello"} = FileAnalyzer.to_utf8(<<0xFF, 0xFE, utf16::binary>>)
    end

    test "decodes UTF-16 BE with BOM to UTF-8" do
      utf16 = :unicode.characters_to_binary("hello", :utf8, {:utf16, :big})
      assert {:ok, "hello"} = FileAnalyzer.to_utf8(<<0xFE, 0xFF, utf16::binary>>)
    end

    test "decodes Latin-1 text to UTF-8" do
      latin1 = :unicode.characters_to_binary("café mañana", :utf8, :latin1)
      assert {:ok, "café mañana"} = FileAnalyzer.to_utf8(latin1)
    end

    test "returns error for binary content" do
      assert {:error, :binary} = FileAnalyzer.to_utf8(<<0, 1, 2, 3>>)
    end
  end
end
