defmodule Magus.Agents.Tools.Brain.BrainGuide do
  @moduledoc """
  Brain Guide tool: on-demand access to a brain's "Guide" (constitution,
  inherited section guides, and the types index) plus, later, the
  actions that let an agent maintain that Guide.

  `get_guide` returns the assembled Guide for a page's location in the
  tree, computed by the shared `Magus.Brain.Guide` module (also used to
  render the Guide into the agent's system-prompt context via
  `Magus.Agents.Context.BrainContext`). It additionally resolves the
  page's own `type` frontmatter (when present) to its matching
  `:template` page, so the agent can fetch the template body itself
  with `read_brain.read_page`.

  `define_type` and `set_page_type` let the agent maintain the types
  index (per-type template pages and each page's classification)
  without hand-editing frontmatter.
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
    - set_page_guide: Sets a section guide on a page (its `instructions:`
      frontmatter), inherited by every descendant page's get_guide
      result. Required one of: page_id, page_title. Required:
      instructions. Merges into the page's existing frontmatter (does
      not clobber `type`, `tags`, or any other key).
    - define_type: Creates or updates a per-type template page (a
      `:template` page titled `type_name`). Optional: brain_id
      (auto-resolved from context when omitted). Required: type_name,
      template_body. Optional: description, merged into the template
      page's `description` frontmatter (surfaces in the brain's types
      index). Upserts by case-insensitive title match against the
      brain's existing template pages, so calling it again with the
      same type_name updates that template instead of creating a
      duplicate.
    - set_page_type: Classifies a page by setting its `type:`
      frontmatter. Required one of: page_id, page_title. Required:
      type. Merges into the page's existing frontmatter (does not
      clobber `instructions`, `tags`, or any other key). A subsequent
      get_guide on the page reports the matching type_template when a
      :template page with that type_name exists.
    """,
    schema: [
      action: [
        type:
          {:in,
           ["get_guide", "set_brain_guide", "set_page_guide", "define_type", "set_page_type"]},
        required: true,
        doc:
          "Action to perform: get_guide | set_brain_guide | set_page_guide | define_type | set_page_type"
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
        doc:
          "set_brain_guide: the brain's constitution. set_page_guide: the page's section guide."
      ],
      type_name: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "define_type: the type's name (also the template page's title)"
      ],
      template_body: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "define_type: the template page's markdown body"
      ],
      description: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "define_type: optional description, merged into the template page's frontmatter"
      ],
      type: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "set_page_type: the page's `type:` frontmatter value"
      ]
    ]

  alias Magus.Brain
  alias Magus.Brain.Frontmatter
  alias Magus.Brain.Guide
  alias Magus.Brain.Page.Errors.VersionConflict
  alias Magus.Agents.Tools.Brain.BrainResolver

  import Magus.Agents.Tools.Helpers,
    only: [validate_context: 2, get_param: 2, nilify_blank_params: 2, tool_error: 3]

  @valid_actions ~w(get_guide set_brain_guide set_page_guide define_type set_page_type)

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

  def summarize_output(%{action: "set_page_guide"}), do: "Updated page guide"

  def summarize_output(%{action: "define_type", type: type}) when is_binary(type),
    do: "Defined type: #{type}"

  def summarize_output(%{action: "define_type"}), do: "Defined type"

  def summarize_output(%{action: "set_page_type", type: type}) when is_binary(type),
    do: "Set page type: #{type}"

  def summarize_output(%{action: "set_page_type"}), do: "Set page type"

  def summarize_output(_), do: "Completed"

  # ---------------------------------------------------------------------------
  # Entry point
  # ---------------------------------------------------------------------------

  @impl true
  def run(params, context) do
    case validate_context(context, [:user_id, :user]) do
      {:ok, ctx} ->
        # LLMs send "" for reference params they mean to omit; a blank id
        # reaching an Ash filter raises InvalidFilterValue. Blank = absent,
        # so resolution falls back (pane context / title lookup) instead.
        params = nilify_blank_params(params, [:brain_id, :page_id, :parent_page_id, :page_title])
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
      type_template = Guide.type_template_for(brain_id, page, ctx.user)

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

  # ---------------------------------------------------------------------------
  # set_page_guide
  # ---------------------------------------------------------------------------

  defp dispatch("set_page_guide", params, ctx, context) do
    instructions = get_param(params, :instructions)

    if blank?(instructions) do
      {:ok, %{error: "Missing required parameter: instructions"}}
    else
      with {:ok, brain_id} <- BrainResolver.resolve_brain_id(context, params),
           {:ok, page} <- BrainResolver.resolve_page(context, params, brain_id) do
        new_body = Frontmatter.put(page.body || "", "instructions", instructions)
        save_page_guide(page, new_body, ctx)
      else
        {:error, msg} when is_binary(msg) -> {:ok, %{error: msg}}
        {:error, err} -> {:ok, %{error: tool_error("set page guide", err, nil)}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # set_page_type
  # ---------------------------------------------------------------------------

  defp dispatch("set_page_type", params, ctx, context) do
    type = get_param(params, :type)

    if blank?(type) do
      {:ok, %{error: "Missing required parameter: type"}}
    else
      with {:ok, brain_id} <- BrainResolver.resolve_brain_id(context, params),
           {:ok, page} <- BrainResolver.resolve_page(context, params, brain_id) do
        new_body = Frontmatter.put(page.body || "", "type", type)
        save_page_type(page, new_body, type, ctx)
      else
        {:error, msg} when is_binary(msg) -> {:ok, %{error: msg}}
        {:error, err} -> {:ok, %{error: tool_error("set page type", err, nil)}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # define_type
  # ---------------------------------------------------------------------------

  defp dispatch("define_type", params, ctx, context) do
    type_name = get_param(params, :type_name)
    template_body = get_param(params, :template_body)

    cond do
      blank?(type_name) ->
        {:ok, %{error: "Missing required parameter: type_name"}}

      blank?(template_body) ->
        {:ok, %{error: "Missing required parameter: template_body"}}

      true ->
        description = get_param(params, :description)

        with {:ok, brain_id} <- BrainResolver.resolve_brain_id(context, params),
             {:ok, composed_body} <- compose_template_body(template_body, description) do
          upsert_template(brain_id, type_name, composed_body, ctx)
        else
          {:error, :invalid_frontmatter} ->
            {:ok,
             %{
               error:
                 "The provided template_body has malformed YAML frontmatter that can't be " <>
                   "safely merged with description. Fix the frontmatter block and retry."
             }}

          {:error, msg} when is_binary(msg) ->
            {:ok, %{error: msg}}

          {:error, err} ->
            {:ok, %{error: tool_error("define type", err, nil)}}
        end
    end
  end

  defp save_page_guide(page, {:error, :invalid_frontmatter}, _ctx) do
    {:ok,
     %{
       error:
         "Page '#{page.title}' has malformed YAML frontmatter that can't be safely merged. " <>
           "Fix the frontmatter block manually with edit_page, then retry."
     }}
  end

  defp save_page_guide(page, new_body, ctx) when is_binary(new_body) do
    case Brain.update_page_body(
           page,
           %{body: new_body, base_version: page.lock_version},
           actor: ctx.user
         ) do
      {:ok, updated} ->
        {:ok, %{action: "set_page_guide", page_id: updated.id}}

      {:error, %Ash.Error.Invalid{errors: errors}} = err ->
        case Enum.find(errors, &match?(%VersionConflict{}, &1)) do
          %VersionConflict{} ->
            {:ok,
             %{
               error:
                 "Concurrent edit detected while setting page guide on '#{page.title}'. " <>
                   "The page changed under you; re-read and retry.",
               conflict: true,
               page_id: page.id
             }}

          nil ->
            {:ok, %{error: tool_error("set page guide", err, nil)}}
        end

      {:error, err} ->
        {:ok,
         %{
           error:
             tool_error(
               "set page guide",
               err,
               "Verify page_id with read_brain list_pages."
             )
         }}
    end
  end

  defp save_page_type(page, {:error, :invalid_frontmatter}, _type, _ctx) do
    {:ok,
     %{
       error:
         "Page '#{page.title}' has malformed YAML frontmatter that can't be safely merged. " <>
           "Fix the frontmatter block manually with edit_page, then retry."
     }}
  end

  defp save_page_type(page, new_body, type, ctx) when is_binary(new_body) do
    case Brain.update_page_body(
           page,
           %{body: new_body, base_version: page.lock_version},
           actor: ctx.user
         ) do
      {:ok, updated} ->
        {:ok, %{action: "set_page_type", page_id: updated.id, type: type}}

      {:error, %Ash.Error.Invalid{errors: errors}} = err ->
        case Enum.find(errors, &match?(%VersionConflict{}, &1)) do
          %VersionConflict{} ->
            {:ok,
             %{
               error:
                 "Concurrent edit detected while setting page type on '#{page.title}'. " <>
                   "The page changed under you; re-read and retry.",
               conflict: true,
               page_id: page.id
             }}

          nil ->
            {:ok, %{error: tool_error("set page type", err, nil)}}
        end

      {:error, err} ->
        {:ok,
         %{
           error:
             tool_error(
               "set page type",
               err,
               "Verify page_id with read_brain list_pages."
             )
         }}
    end
  end

  # Merges `description` into `template_body`'s frontmatter when present;
  # otherwise returns the body unchanged. `Frontmatter.put/3` creates a
  # frontmatter block if one doesn't already exist.
  defp compose_template_body(template_body, description) do
    if blank?(description) do
      {:ok, template_body}
    else
      case Frontmatter.put(template_body, "description", description) do
        {:error, :invalid_frontmatter} = error -> error
        composed when is_binary(composed) -> {:ok, composed}
      end
    end
  end

  # Upserts the `:template` page titled `type_name` (case-insensitive match
  # against the brain's existing templates, via `Guide.find_template_by_type/2`):
  # writes the composed body to the existing page when found, else creates a
  # fresh `:template` page and writes the body to it.
  defp upsert_template(brain_id, type_name, composed_body, ctx) do
    with {:ok, templates} <- Brain.templates_for_brain(brain_id, actor: ctx.user) do
      case Guide.find_template_by_type(templates, type_name) do
        %{} = existing ->
          write_template_body(existing, type_name, composed_body, ctx)

        nil ->
          create_template(brain_id, type_name, composed_body, ctx)
      end
    else
      {:error, err} -> {:ok, %{error: tool_error("define type", err, nil)}}
    end
  end

  defp create_template(brain_id, type_name, composed_body, ctx) do
    with {:ok, page} <-
           Brain.create_page(brain_id, %{title: type_name, kind: :template}, actor: ctx.user) do
      write_template_body(page, type_name, composed_body, ctx)
    else
      {:error, err} -> {:ok, %{error: tool_error("define type", err, nil)}}
    end
  end

  defp write_template_body(page, type_name, composed_body, ctx) do
    case Brain.update_page_body(
           page,
           %{body: composed_body, base_version: page.lock_version},
           actor: ctx.user
         ) do
      {:ok, updated} ->
        {:ok, %{action: "define_type", type: type_name, page_id: updated.id}}

      {:error, %Ash.Error.Invalid{errors: errors}} = err ->
        case Enum.find(errors, &match?(%VersionConflict{}, &1)) do
          %VersionConflict{} ->
            {:ok,
             %{
               error:
                 "Concurrent edit detected while defining type '#{type_name}'. " <>
                   "The template page changed under you; re-read and retry.",
               conflict: true,
               page_id: page.id
             }}

          nil ->
            {:ok, %{error: tool_error("define type", err, nil)}}
        end

      {:error, err} ->
        {:ok, %{error: tool_error("define type", err, nil)}}
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  # Resolves the page's frontmatter `type` (if present) to the `:template`
  # page in the same brain whose title matches case-insensitively. Returns
  # nil when the page has no type or no template title matches.
end
