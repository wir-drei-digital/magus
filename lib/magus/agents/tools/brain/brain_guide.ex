defmodule Magus.Agents.Tools.Brain.BrainGuide do
  @moduledoc """
  Brain Guide tool: on-demand access to a brain's "Guide" (constitution,
  inherited section guides, and the types index) plus, later, the
  actions that let an agent maintain that Guide.

  `get_guide` (this task) returns the assembled Guide for a page's
  location in the tree, computed by the shared `Magus.Brain.Guide`
  module (also used to render the Guide into the agent's system-prompt
  context via `Magus.Agents.Context.BrainContext`). It additionally
  resolves the page's own `type` frontmatter (when present) to its
  matching `:template` page, so the agent can fetch the template body
  itself with `read_brain.read_page`.

  Future actions on this tool (set_page_guide, define_type,
  set_page_type) will let the agent maintain the section guides and
  types index without hand-editing frontmatter.
  """

  use Jido.Action,
    name: "brain_guide",
    description: """
    Read and maintain a brain's "Guide": the constitution (brain-wide
    instructions), inherited section guides for a page's location in
    the tree, and the types index (from :template pages).

    Actions:
    - get_guide: Returns the Guide for a page's location in the brain.
      Optional: brain_id (auto-resolved from context when omitted).
      Required one of: page_id, page_title. Returns constitution
      (brain.instructions, or null), section_guides (ordered
      root-to-current, nearest last), and type_template (the :template
      page matching the current page's frontmatter `type`, or null when
      the page has no type or no template matches).
    - set_brain_guide: Sets the brain's constitution (brain-wide
      instructions). Optional: brain_id (auto-resolved from context
      when omitted). Required: instructions.
    """,
    schema: [
      action: [
        type: {:in, ["get_guide", "set_brain_guide"]},
        required: true,
        doc: "Action to perform: get_guide | set_brain_guide"
      ],
      brain_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Brain id, slug, or title (auto-resolved if omitted)"
      ],
      page_id: [type: {:or, [:string, nil]}, default: nil, doc: "Page ID"],
      page_title: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Page title (lookup within brain)"
      ],
      instructions: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "set_brain_guide: the brain's constitution (brain-wide instructions)"
      ]
    ]

  alias Magus.Brain
  alias Magus.Brain.Guide
  alias Magus.Agents.Tools.Brain.BrainResolver

  import Magus.Agents.Tools.Helpers,
    only: [validate_context: 2, get_param: 2, tool_error: 3]

  @valid_actions ~w(get_guide set_brain_guide)

  def display_name, do: "Reading brain guide..."

  def summarize_output(%{error: error}) when is_binary(error), do: "Error: #{error}"

  def summarize_output(%{action: "get_guide", type_template: nil}),
    do: "Loaded brain guide"

  def summarize_output(%{action: "get_guide", type_template: %{title: title}}),
    do: "Loaded brain guide (type: #{title})"

  def summarize_output(%{action: "set_brain_guide", brain_title: title})
      when is_binary(title),
      do: "Updated brain guide: #{title}"

  def summarize_output(%{action: "set_brain_guide"}), do: "Updated brain guide"

  def summarize_output(_), do: "Completed"

  # ---------------------------------------------------------------------------
  # Entry point
  # ---------------------------------------------------------------------------

  @impl true
  def run(params, context) do
    case validate_context(context, [:user_id, :user]) do
      {:ok, ctx} ->
        action = get_param(params, :action)
        dispatch(action, params, ctx, context)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp dispatch(action, _params, _ctx, _context) when action not in @valid_actions do
    valid = Enum.join(@valid_actions, ", ")

    if is_nil(action) do
      {:ok, %{error: "Missing required parameter: action. Must be one of: #{valid}"}}
    else
      {:ok, %{error: "Unknown action '#{action}'. Must be one of: #{valid}"}}
    end
  end

  # ---------------------------------------------------------------------------
  # get_guide
  # ---------------------------------------------------------------------------

  defp dispatch("get_guide", params, ctx, context) do
    with {:ok, brain_id} <- BrainResolver.resolve_brain_id(context, params),
         {:ok, brain} <- Brain.get_brain(brain_id, actor: ctx.user),
         {:ok, page} <- BrainResolver.resolve_page(context, params, brain_id),
         {:ok, pages} <- Brain.list_pages(brain_id, actor: ctx.user) do
      guide = Guide.for_page(brain, page, pages, ctx.user)
      type_template = resolve_type_template(brain_id, page, ctx.user)

      {:ok,
       %{
         action: "get_guide",
         constitution: guide.constitution,
         section_guides: guide.section_guides,
         type_template: type_template
       }}
    else
      {:error, msg} when is_binary(msg) -> {:ok, %{error: msg}}
      {:error, err} -> {:ok, %{error: tool_error("get brain guide", err, nil)}}
    end
  end

  # ---------------------------------------------------------------------------
  # set_brain_guide
  # ---------------------------------------------------------------------------

  defp dispatch("set_brain_guide", params, ctx, context) do
    instructions = get_param(params, :instructions)

    if blank?(instructions) do
      {:ok, %{error: "Missing required parameter: instructions"}}
    else
      with {:ok, brain_id} <- BrainResolver.resolve_brain_id(context, params),
           {:ok, brain} <- Brain.get_brain(brain_id, actor: ctx.user),
           {:ok, updated} <-
             Brain.set_brain_instructions(brain, %{instructions: instructions}, actor: ctx.user) do
        {:ok,
         %{
           action: "set_brain_guide",
           brain_id: updated.id,
           brain_title: updated.title
         }}
      else
        {:error, msg} when is_binary(msg) -> {:ok, %{error: msg}}
        {:error, err} -> {:ok, %{error: tool_error("set brain guide", err, nil)}}
      end
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  # Resolves the page's frontmatter `type` (if present) to the `:template`
  # page in the same brain whose title matches case-insensitively. Returns
  # nil when the page has no type or no template title matches.
  defp resolve_type_template(brain_id, page, actor) do
    with type when is_binary(type) and type != "" <- page_type(page),
         {:ok, templates} <- Brain.templates_for_brain(brain_id, actor: actor),
         template when not is_nil(template) <- find_template_by_type(templates, type) do
      %{page_id: template.id, title: template.title}
    else
      _ -> nil
    end
  end

  defp page_type(%{frontmatter: fm}) when is_map(fm) do
    case Map.get(fm, "type") do
      type when is_binary(type) -> String.trim(type)
      _ -> nil
    end
  end

  defp page_type(_), do: nil

  defp find_template_by_type(templates, type) do
    lowered = String.downcase(type)
    Enum.find(templates, fn t -> is_binary(t.title) and String.downcase(t.title) == lowered end)
  end
end
