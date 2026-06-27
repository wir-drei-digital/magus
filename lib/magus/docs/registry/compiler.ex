defmodule Magus.Docs.Registry.Compiler do
  @moduledoc false
  # Compile-time helpers for parsing doc files.
  # In its own module (and file) so these functions are already compiled and
  # available when the Registry module computes its @compiled_docs attribute.

  def parse_frontmatter("---\n" <> rest) do
    case String.split(rest, "\n---\n", parts: 2) do
      [yaml, body] ->
        case YamlElixir.read_from_string(yaml) do
          {:ok, meta} -> {:ok, meta, String.trim(body)}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def parse_frontmatter(_), do: :error

  def render_markdown(body) do
    MDEx.to_html(body,
      extension: [
        strikethrough: true,
        table: true,
        autolink: true,
        tasklist: true,
        footnotes: true
      ],
      parse: [smart: true],
      render: [github_pre_lang: true, unsafe: true],
      sanitize: MDEx.Document.default_sanitize_options()
    )
  end
end
