defmodule Magus.Brain.Frontmatter do
  @moduledoc """
  YAML frontmatter parsing and serialization for page bodies.

  A page body may optionally begin with a `---`-delimited YAML block:

      ---
      icon: 🧠
      tags: [ml, research]
      aliases: [Old Name]
      ---

      # Page title

      Body content...

  This module:

    * parses the frontmatter into a map (via `yaml_front_matter`),
    * normalizes the known keys (`icon`, `tags`, `aliases`),
    * preserves unknown keys opaquely so future schema additions are
      non-breaking,
    * serializes a known-keys map back into a YAML block via `dump/1`.

  In Phase A this module is defined but unused; Phase C wires it into the
  `Page.update_body` after-action pipeline to populate the `frontmatter`
  jsonb cache column.
  """

  @known_keys ~w(icon tags aliases created modified instructions type)

  @doc """
  Parses a page body string and returns `{frontmatter_map, body_without_frontmatter}`.

  When the body has no frontmatter (no leading `---` block) returns `{%{}, body}`.
  When the leading `---` block is present but malformed, returns
  `{:error, :invalid_frontmatter}`.

  ## Examples

      iex> Magus.Brain.Frontmatter.parse("# Hello\\n")
      {%{}, "# Hello\\n"}

      iex> Magus.Brain.Frontmatter.parse("---\\nicon: 🧠\\n---\\n# Hello\\n")
      {%{"icon" => "🧠"}, "# Hello\\n"}
  """
  @spec parse(binary()) :: {map(), binary()} | {:error, :invalid_frontmatter}
  def parse(body) when is_binary(body) do
    # Only treat the body as having a frontmatter block when the very first
    # line is `---`. YamlFrontMatter happily picks up any `---`-bounded
    # region anywhere in the body (e.g. GFM table separators `| --- |`),
    # which would otherwise mis-parse normal Markdown as frontmatter.
    if has_leading_delimiter?(body) do
      case YamlFrontMatter.parse(body) do
        {:ok, matter, rest} ->
          {normalize_known_keys(matter), rest}

        {:error, :invalid_front_matter} ->
          if looks_like_frontmatter?(body),
            do: {:error, :invalid_frontmatter},
            else: {%{}, body}

        {:error, _other} ->
          {:error, :invalid_frontmatter}
      end
    else
      {%{}, body}
    end
  end

  defp has_leading_delimiter?(body) do
    body
    |> String.split(["\r\n", "\n"], parts: 2)
    |> List.first()
    |> Kernel.||("")
    |> String.trim()
    |> Kernel.==("---")
  end

  @doc """
  Serializes a frontmatter map into a `---`-delimited YAML block.

  Returns the empty string for an empty map (so an empty frontmatter
  isn't materialized as a redundant `---\\n---` block). Only handles the
  scalar/list types we actually use (`icon`, `tags`, `aliases`); arbitrary
  nested structures are not supported because we don't produce them.

  Input keys must be strings. `parse/1` always returns string-keyed maps,
  so callers that serialize what they parsed are safe. Atom-keyed input
  would sort incorrectly relative to string keys (atoms sort before
  strings in Elixir term ordering) and is rejected with `ArgumentError`.
  """
  @spec dump(map()) :: binary()
  def dump(matter) when matter == %{}, do: ""

  def dump(matter) when is_map(matter) do
    unless Enum.all?(Map.keys(matter), &is_binary/1) do
      raise ArgumentError,
            "Magus.Brain.Frontmatter.dump/1 requires string keys; got #{inspect(Map.keys(matter))}"
    end

    body =
      matter
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{dump_value(v)}" end)

    "---\n" <> body <> "\n---\n"
  end

  @doc """
  Normalizes the known frontmatter keys:

    * `icon` is coerced to a string (or dropped if not a scalar)
    * `tags` is normalized to a list of lowercase, whitespace-stripped tags
    * `aliases` is normalized to a list of strings (case preserved; aliases are
      matched case-insensitively at resolve time)

  Unknown keys are passed through untouched.
  """
  @spec normalize_known_keys(map() | nil | any()) :: map()
  def normalize_known_keys(matter) when is_map(matter) do
    Enum.reduce(matter, %{}, fn {k, v}, acc ->
      key = to_string(k)

      cond do
        key == "icon" -> put_if_present(acc, key, normalize_icon(v))
        key == "tags" -> put_if_present(acc, key, normalize_tags(v))
        key == "aliases" -> put_if_present(acc, key, normalize_aliases(v))
        key == "instructions" -> put_if_present(acc, key, normalize_text(v))
        key == "type" -> put_if_present(acc, key, normalize_text(v))
        true -> Map.put(acc, key, v)
      end
    end)
  end

  # YAML can parse a frontmatter-shaped block to a non-map (nil, scalar
  # string, list, etc.) when the content isn't a key-value mapping. Treat
  # those as "no usable frontmatter" rather than crashing the caller.
  def normalize_known_keys(_), do: %{}

  @doc "List of frontmatter keys this module knows about."
  def known_keys, do: @known_keys

  @doc """
  Normalizes a tag string the way both the `tags:` frontmatter list and the
  inline `#tag` syntax are normalized: lowercase, no whitespace.
  """
  @spec normalize_tag(binary()) :: binary()
  def normalize_tag(tag) when is_binary(tag) do
    tag
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, "-")
  end

  defp normalize_icon(v) when is_binary(v), do: v
  defp normalize_icon(v) when is_number(v) or is_atom(v), do: to_string(v)
  defp normalize_icon(_), do: nil

  defp normalize_text(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      t -> t
    end
  end

  defp normalize_text(v) when is_number(v) or is_atom(v), do: normalize_text(to_string(v))
  defp normalize_text(_), do: nil

  defp normalize_tags(v) when is_list(v) do
    v
    |> Enum.map(&to_string/1)
    |> Enum.map(&normalize_tag/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_tags(v) when is_binary(v) do
    v
    |> String.split([",", " "], trim: true)
    |> Enum.map(&normalize_tag/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_tags(_), do: []

  defp normalize_aliases(v) when is_list(v) do
    v
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_aliases(v) when is_binary(v) do
    v
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_aliases(_), do: []

  defp put_if_present(acc, _key, nil), do: acc
  defp put_if_present(acc, _key, []), do: acc
  defp put_if_present(acc, key, value), do: Map.put(acc, key, value)

  defp dump_value(v) when is_binary(v), do: dump_scalar(v)
  defp dump_value(v) when is_number(v), do: to_string(v)
  defp dump_value(v) when is_atom(v), do: dump_scalar(to_string(v))

  defp dump_value(v) when is_list(v) do
    items = Enum.map_join(v, ", ", &dump_scalar(to_string(&1)))
    "[" <> items <> "]"
  end

  defp dump_scalar(s) when is_binary(s) do
    cond do
      String.contains?(s, ["\n", "\r"]) ->
        # Multi-line scalars need block-style quoting; we don't produce them
        # in any current code path, so refuse rather than emit invalid YAML.
        raise ArgumentError,
              "Magus.Brain.Frontmatter.dump/1 does not support multi-line scalars"

      String.contains?(s, [":", "#", "[", "]", "{", "}", ",", "\"", "\\"]) or
        String.starts_with?(s, " ") or String.ends_with?(s, " ") ->
        escaped = s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
        ~s("#{escaped}")

      true ->
        s
    end
  end

  defp looks_like_frontmatter?(body) do
    # We don't want the harmless `---` horizontal rule at the top of a body to
    # be treated as a malformed frontmatter block.  Only treat it as a
    # frontmatter attempt if there's at least one `key: value` looking line
    # before the next `---`.
    case String.split(body, ~r/^---\s*$/m, parts: 3) do
      ["", header, _rest] -> Regex.match?(~r/^\s*\w[\w-]*\s*:/m, header)
      _ -> false
    end
  end
end
