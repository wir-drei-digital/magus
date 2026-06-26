defmodule Magus.Integrations.Providers.Telegram.FormatterTest do
  use ExUnit.Case, async: true

  alias Magus.Integrations.Providers.Telegram.Formatter

  describe "to_telegram_html/1" do
    test "returns empty string for nil" do
      assert Formatter.to_telegram_html(nil) == ""
    end

    test "passes plain text through with HTML escaping" do
      assert Formatter.to_telegram_html("Hello world") == "Hello world"
      assert Formatter.to_telegram_html("a < b & c > d") == "a &lt; b &amp; c &gt; d"
    end

    test "converts bold markdown" do
      assert Formatter.to_telegram_html("**bold text**") == "<b>bold text</b>"
      assert Formatter.to_telegram_html("__bold text__") == "<b>bold text</b>"
    end

    test "converts italic markdown" do
      assert Formatter.to_telegram_html("*italic text*") == "<i>italic text</i>"
      assert Formatter.to_telegram_html("_italic text_") == "<i>italic text</i>"
    end

    test "converts strikethrough" do
      assert Formatter.to_telegram_html("~~deleted~~") == "<s>deleted</s>"
    end

    test "converts inline code" do
      assert Formatter.to_telegram_html("use `mix test` here") ==
               "use <code>mix test</code> here"
    end

    test "converts fenced code blocks" do
      input = """
      ```elixir
      def hello, do: :world
      ```
      """

      result = Formatter.to_telegram_html(input)
      assert result =~ ~s(<pre><code class="language-elixir">)
      assert result =~ "def hello, do: :world"
      assert result =~ "</code></pre>"
    end

    test "converts fenced code blocks without language" do
      input = """
      ```
      some code
      ```
      """

      result = Formatter.to_telegram_html(input)
      assert result =~ "<pre><code>"
      assert result =~ "some code"
      refute result =~ "class="
    end

    test "escapes HTML inside code blocks" do
      input = """
      ```
      <div>hello</div>
      ```
      """

      result = Formatter.to_telegram_html(input)
      assert result =~ "&lt;div&gt;hello&lt;/div&gt;"
    end

    test "converts links" do
      assert Formatter.to_telegram_html("[click here](https://example.com)") ==
               ~s(<a href="https://example.com">click here</a>)
    end

    test "converts image markdown to alt text only" do
      assert Formatter.to_telegram_html("![a photo](https://example.com/img.png)") == "a photo"
    end

    test "converts headers to bold" do
      assert Formatter.to_telegram_html("# Heading 1") == "<b>Heading 1</b>"
      assert Formatter.to_telegram_html("## Heading 2") == "<b>Heading 2</b>"
      assert Formatter.to_telegram_html("### Heading 3") == "<b>Heading 3</b>"
    end

    test "converts blockquotes" do
      assert Formatter.to_telegram_html("> quoted text") ==
               "<blockquote>quoted text</blockquote>"
    end

    test "converts horizontal rules" do
      assert Formatter.to_telegram_html("---") == "———"
      assert Formatter.to_telegram_html("***") == "———"
    end

    test "converts unordered list items to bullet points" do
      input = "- item one\n- item two\n- item three"
      result = Formatter.to_telegram_html(input)
      assert result == "• item one\n• item two\n• item three"
    end

    test "preserves ordered list items" do
      input = "1. first\n2. second"
      result = Formatter.to_telegram_html(input)
      assert result =~ "1. first"
      assert result =~ "2. second"
    end

    test "handles mixed formatting" do
      input = "**bold** and *italic* and `code`"
      result = Formatter.to_telegram_html(input)
      assert result == "<b>bold</b> and <i>italic</i> and <code>code</code>"
    end

    test "handles multi-paragraph text with formatting" do
      input = """
      # Welcome

      Here is some **bold** text and a [link](https://example.com).

      > A wise quote

      - Item 1
      - Item 2
      """

      result = Formatter.to_telegram_html(input)
      assert result =~ "<b>Welcome</b>"
      assert result =~ "<b>bold</b>"
      assert result =~ ~s(<a href="https://example.com">link</a>)
      assert result =~ "<blockquote>"
      assert result =~ "• Item 1"
      assert result =~ "• Item 2"
    end

    test "does not mangle code block contents with markdown-like syntax" do
      input = """
      ```
      **not bold** and *not italic*
      ```
      """

      result = Formatter.to_telegram_html(input)
      # Inside code blocks, markdown should NOT be converted
      refute result =~ "<b>"
      refute result =~ "<i>"
      assert result =~ "**not bold**"
      assert result =~ "*not italic*"
    end

    test "handles multiple code blocks" do
      input = """
      First block:
      ```python
      print("hello")
      ```

      Second block:
      ```js
      console.log("hi")
      ```
      """

      result = Formatter.to_telegram_html(input)
      assert result =~ ~s(class="language-python")
      assert result =~ ~s(class="language-js")
      assert result =~ ~s(print\("hello"\))
    end
  end
end
