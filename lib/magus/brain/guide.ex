defmodule Magus.Brain.Guide do
  @moduledoc """
  Assembles a brain's "Guide": the constitution (brain-wide instructions),
  inherited section guides for a page's location in the tree, and the
  brain's types index (from `:template` pages).

  Shared assembly logic for two consumers:

    * `Magus.Agents.Context.BrainContext` renders it into the agent's
      system-prompt context (Phase B, Task B4).
    * The `brain_guide` tool's `get_guide` action returns it directly to
      the agent on demand (Phase B, Task B5).

  Keeping the computation here (independent of Markdown rendering) avoids
  duplicating the ancestor-walk / template-lookup logic between the two.
  """

  require Ash.Query

  alias Magus.Brain
  alias Magus.Brain.Hierarchy
  alias Magus.Brain.Page

  @constitution_line_cap 200

  @type section_guide :: %{page_id: String.t(), title: String.t(), instructions: String.t()}
  @type type_entry :: %{title: String.t(), description: String.t()}

  @type t :: %{
          constitution: String.t() | nil,
          section_guides: [section_guide()],
          types: [type_entry()]
        }

  @doc """
  Builds the Guide for `page`'s location within `brain`.

  `pages` is the brain's page list (used for the ancestor walk via
  `Hierarchy.ancestor_pages/2`); if any ancestor in that list is missing
  its cached `frontmatter` (e.g. a caller passed stripped fixtures), the
  ancestor ids are re-queried for just that attribute.

  `actor` authorizes the `templates_for_brain` lookup.
  """
  @spec for_page(Ash.Resource.record(), Ash.Resource.record(), [Ash.Resource.record()], term()) ::
          t()
  def for_page(brain, page, pages, actor) do
    %{
      constitution: build_constitution(brain.instructions),
      section_guides: build_section_guides(page, pages, actor),
      types: build_types(brain.id, actor)
    }
  end

  @doc "True when the Guide has no constitution, no section guides, and no types."
  @spec empty?(t()) :: boolean()
  def empty?(%{constitution: nil, section_guides: [], types: []}), do: true
  def empty?(_), do: false

  @doc """
  The page's declared type: the trimmed `type:` frontmatter value, or nil.
  """
  @spec page_type(Ash.Resource.record() | map()) :: String.t() | nil
  def page_type(%{frontmatter: fm}) when is_map(fm) do
    case Map.get(fm, "type") do
      type when is_binary(type) ->
        case String.trim(type) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  def page_type(_), do: nil

  @doc """
  Resolves the page's type to its template page (a `:template` page whose
  title matches the type, case-insensitively). Returns `%{page_id, title}`
  or nil when the page is untyped or no template exists for the type.

  Shared by the `brain_guide` tool's `get_guide` and the SPA-facing
  `guide_for_page` action so both resolve identically.
  """
  @spec type_template_for(String.t(), Ash.Resource.record() | map(), term()) ::
          %{page_id: String.t(), title: String.t() | nil} | nil
  def type_template_for(brain_id, page, actor) do
    with type when is_binary(type) <- page_type(page),
         {:ok, templates} <- Brain.templates_for_brain(brain_id, actor: actor),
         template when not is_nil(template) <- find_template_by_type(templates, type) do
      %{page_id: template.id, title: template.title}
    else
      _ -> nil
    end
  end

  @doc """
  Finds the template page whose title matches `type` case-insensitively,
  or nil. Types are matched to templates by title everywhere (get_guide,
  define_type upsert, off_template curation), so the matching rule lives
  in one place.
  """
  @spec find_template_by_type([Ash.Resource.record()], String.t()) ::
          Ash.Resource.record() | nil
  def find_template_by_type(templates, type) do
    lowered = String.downcase(type)
    Enum.find(templates, fn t -> is_binary(t.title) and String.downcase(t.title) == lowered end)
  end

  # ----- constitution -----

  defp build_constitution(instructions) when is_binary(instructions) do
    case String.trim(instructions) do
      "" -> nil
      trimmed -> cap_lines(trimmed)
    end
  end

  defp build_constitution(_), do: nil

  defp cap_lines(text) do
    lines = String.split(text, "\n")

    if length(lines) > @constitution_line_cap do
      capped = lines |> Enum.take(@constitution_line_cap) |> Enum.join("\n")

      capped <>
        "\n\n_(truncated at #{@constitution_line_cap} lines; #{length(lines) - @constitution_line_cap} more not shown)_"
    else
      text
    end
  end

  # ----- section guides -----

  # Root-to-current: ancestors (already root-first from Hierarchy) followed
  # by the active page itself, so the nearest guide renders last (nearest
  # wins, matching CLAUDE.md-style precedence).
  defp build_section_guides(page, pages, actor) do
    ancestors = Hierarchy.ancestor_pages(page, pages)
    chain = ancestors ++ [page]
    frontmatter_by_id = frontmatter_index(chain, actor)

    chain
    |> Enum.map(fn p ->
      fm = Map.get(frontmatter_by_id, p.id, normalize_frontmatter(p))
      {p, Map.get(fm, "instructions")}
    end)
    |> Enum.filter(fn {_p, instructions} -> present?(instructions) end)
    |> Enum.map(fn {p, instructions} ->
      %{page_id: p.id, title: p.title || "Untitled", instructions: String.trim(instructions)}
    end)
  end

  # Loads `frontmatter` for any chain page that doesn't already carry it
  # (defensive: `pages`/`page` are normally full records with `frontmatter`
  # already loaded, but callers can pass stripped fixtures).
  defp frontmatter_index(chain, actor) do
    missing_ids =
      chain
      |> Enum.reject(&Map.has_key?(&1, :frontmatter))
      |> Enum.map(& &1.id)

    case missing_ids do
      [] ->
        %{}

      ids ->
        Page
        |> Ash.Query.filter(id in ^ids)
        |> Ash.read!(actor: actor)
        |> Map.new(&{&1.id, normalize_frontmatter(&1)})
    end
  end

  defp normalize_frontmatter(%{frontmatter: fm}) when is_map(fm), do: fm
  defp normalize_frontmatter(_), do: %{}

  defp present?(v) when is_binary(v), do: String.trim(v) != ""
  defp present?(_), do: false

  # ----- types index -----

  defp build_types(brain_id, actor) do
    case Brain.templates_for_brain(brain_id, actor: actor) do
      {:ok, templates} -> Enum.map(templates, &type_entry/1)
      _ -> []
    end
  end

  defp type_entry(template) do
    %{
      title: template.title || "Untitled",
      description: frontmatter_description(template) || first_body_line(template.body)
    }
  end

  # The `define_type` tool action (and hand-edited frontmatter) can set an
  # explicit `description:` key on a template page; prefer it over the
  # derived first-body-line when present, since it's an intentional
  # description rather than an incidental opening line.
  defp frontmatter_description(%{frontmatter: fm}) when is_map(fm) do
    case Map.get(fm, "description") do
      description when is_binary(description) ->
        case String.trim(description) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp frontmatter_description(_), do: nil

  # First non-empty, non-heading line of the body, trimmed. Headings are
  # skipped (not just stripped of `#`) because a template's leading
  # `# Title` heading almost always just repeats the page title, which
  # would make the description redundant ("Meeting Note: Meeting Note").
  defp first_body_line(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&heading_line?/1)
    |> Enum.find("", &(&1 != ""))
  end

  defp first_body_line(_), do: ""

  defp heading_line?(line), do: Regex.match?(~r/^\#{1,6}(\s|$)/, line)
end
