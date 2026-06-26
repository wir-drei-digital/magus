defmodule Magus.Agents.Context.SectionMarker do
  @moduledoc """
  Explicit category markers for the assembled system-prompt sections.

  `Magus.Agents.Context.ContextReport` breaks the context window into a
  per-section token breakdown. Inferring each section's category from its
  first-line heading is brittle: a stray `## Tasks` heading inside a custom
  system prompt or retrieved content would be miscounted as our Tasks section.

  Instead, every section WE assemble is prefixed with a hidden marker line —
  `<!--ctx:tasks-->` — that names its category unambiguously. ContextReport reads
  the marker first; only genuinely unmarked text (arbitrary user / retrieved
  content) is attributed to "Other (system)".

  The marker is an HTML comment: inert to the model, byte-stable so the prompt
  prefix stays cacheable, and a handful of tokens.
  """

  @prefix "<!--ctx:"
  @suffix "-->"

  @doc """
  Prefix a non-empty section body with its category marker line. A `nil`/empty
  body passes through unchanged so the caller's own reject/join still drops it.
  """
  @spec wrap(atom(), String.t() | nil) :: String.t() | nil
  def wrap(_category, body) when body in [nil, ""], do: body

  def wrap(category, body) when is_atom(category) and is_binary(body),
    do: "#{@prefix}#{category}#{@suffix}\n" <> body

  @doc """
  Category atom parsed from a section's first-line marker, or `nil` when the
  line carries no marker. Unknown marker keys (atoms that do not already exist)
  also return `nil` rather than minting atoms from untrusted text.
  """
  @spec category(String.t() | nil) :: atom() | nil
  def category(first_line) when is_binary(first_line) do
    case Regex.run(~r/^<!--ctx:([a-z_]+)-->/, first_line) do
      [_, key] -> safe_existing_atom(key)
      _ -> nil
    end
  end

  def category(_), do: nil

  defp safe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
