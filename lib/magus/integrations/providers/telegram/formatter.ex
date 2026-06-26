defmodule Magus.Integrations.Providers.Telegram.Formatter do
  @moduledoc """
  Converts standard Markdown to Telegram-compatible HTML.

  Telegram's Bot API supports a limited HTML subset:
  - `<b>` bold
  - `<i>` italic
  - `<u>` underline
  - `<s>` strikethrough
  - `<code>` inline code
  - `<pre><code class="language-...">` code blocks
  - `<a href="...">` links
  - `<blockquote>` block quotes

  Standard Markdown elements without a Telegram equivalent (headers, horizontal
  rules, images, tables) are converted to the closest approximation.
  """

  @doc """
  Convert Markdown text to Telegram HTML.

  Returns the converted string ready to be sent with `parse_mode: "HTML"`.
  """
  @spec to_telegram_html(String.t()) :: String.t()
  def to_telegram_html(text) when is_binary(text) do
    text
    |> extract_code_blocks()
    |> process_lines()
    |> apply_inline_formatting()
    |> restore_code_blocks()
    |> String.trim()
  end

  def to_telegram_html(nil), do: ""

  # ---------------------------------------------------------------------------
  # Code block extraction — pull fenced code blocks out before any other
  # processing so their contents aren't mangled by inline rules.
  # ---------------------------------------------------------------------------

  @code_block_placeholder "\x00CODE_BLOCK_%d\x00"

  defp extract_code_blocks(text) do
    {result, blocks, _counter} =
      Regex.scan(~r/```(\w*)\n(.*?)```/s, text, return: :index)
      |> Enum.reduce({text, [], 0}, fn [
                                         {full_start, full_len},
                                         {lang_start, lang_len},
                                         {code_start, code_len}
                                       ],
                                       {current_text, acc_blocks, counter} ->
        full_match = String.slice(text, full_start, full_len)
        lang = String.slice(text, lang_start, lang_len)
        code = String.slice(text, code_start, code_len)

        placeholder = String.replace(@code_block_placeholder, "%d", to_string(counter))

        new_text = String.replace(current_text, full_match, placeholder, global: false)

        escaped_code = escape_html(code)

        html =
          if lang == "" do
            "<pre><code>#{escaped_code}</code></pre>"
          else
            "<pre><code class=\"language-#{escape_html(lang)}\">#{escaped_code}</code></pre>"
          end

        {new_text, acc_blocks ++ [{placeholder, html}], counter + 1}
      end)

    {result, blocks}
  end

  # ---------------------------------------------------------------------------
  # Line-level processing — headers, blockquotes, horizontal rules, list items
  # ---------------------------------------------------------------------------

  defp process_lines({text, blocks}) do
    processed =
      text
      |> String.split("\n")
      |> Enum.map(&process_line/1)
      |> Enum.join("\n")

    {processed, blocks}
  end

  defp process_line(line) do
    cond do
      # ATX headers → bold text
      Regex.match?(~r/^\#{1,6}\s/, line) ->
        heading_text = Regex.replace(~r/^\#{1,6}\s+/, line, "")
        "<b>#{escape_html(heading_text)}</b>"

      # Blockquote
      Regex.match?(~r/^>\s?/, line) ->
        quote_text = Regex.replace(~r/^>\s?/, line, "")
        "<blockquote>#{escape_html(quote_text)}</blockquote>"

      # Horizontal rule
      Regex.match?(~r/^[-*_]{3,}\s*$/, line) ->
        "———"

      # Unordered list items — normalize to bullet
      Regex.match?(~r/^\s*[-*+]\s/, line) ->
        item_text = Regex.replace(~r/^\s*[-*+]\s+/, line, "")
        "• #{item_text}"

      # Ordered list items — keep number
      Regex.match?(~r/^\s*\d+\.\s/, line) ->
        line

      # Regular line — escape HTML entities but preserve code block placeholders
      true ->
        if String.contains?(line, "\x00CODE_BLOCK_") do
          line
        else
          escape_html(line)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Inline formatting — applied after line processing and HTML escaping
  # ---------------------------------------------------------------------------

  defp apply_inline_formatting({text, blocks}) do
    processed =
      text
      # Inline code (must come before bold/italic to avoid conflicts)
      |> replace_inline_code()
      # Images → just the alt text (Telegram doesn't inline images in HTML mode)
      |> regex_replace(~r/!\[([^\]]*)\]\([^)]+\)/, "\\1")
      # Links
      |> regex_replace(~r/\[([^\]]+)\]\(([^)]+)\)/, "<a href=\"\\2\">\\1</a>")
      # Bold: **text** or __text__
      |> regex_replace(~r/\*\*(.+?)\*\*/s, "<b>\\1</b>")
      |> regex_replace(~r/__(.+?)__/s, "<b>\\1</b>")
      # Italic: *text* or _text_ (but not inside words for underscores)
      |> regex_replace(~r/(?<!\w)\*(?!\s)(.+?)(?<!\s)\*(?!\w)/s, "<i>\\1</i>")
      |> regex_replace(~r/(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)/s, "<i>\\1</i>")
      # Strikethrough: ~~text~~
      |> regex_replace(~r/~~(.+?)~~/s, "<s>\\1</s>")

    {processed, blocks}
  end

  # Pipe-friendly wrapper: puts the string first so it works with |>
  defp regex_replace(string, regex, replacement) do
    Regex.replace(regex, string, replacement)
  end

  # Inline code needs special handling: escape HTML inside, wrap with <code>
  defp replace_inline_code(text) do
    Regex.replace(~r/`([^`]+?)`/, text, fn _, code ->
      "<code>#{code}</code>"
    end)
  end

  # ---------------------------------------------------------------------------
  # Restore code blocks
  # ---------------------------------------------------------------------------

  defp restore_code_blocks({text, blocks}) do
    Enum.reduce(blocks, text, fn {placeholder, html}, acc ->
      String.replace(acc, placeholder, html)
    end)
  end

  # ---------------------------------------------------------------------------
  # HTML escaping — only the three characters Telegram requires
  # ---------------------------------------------------------------------------

  defp escape_html(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
