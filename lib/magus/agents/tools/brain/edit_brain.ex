defmodule Magus.Agents.Tools.Brain.EditBrain do
  @moduledoc """
  Brain mutation tool. Pages are markdown documents that the agent reads,
  writes, edits, and clears the same way it would touch files in the
  sandbox. Links between pages use `[[Page Name]]` wikilink syntax inside
  the body; tags use inline `#tag` or a `tags:` array in YAML frontmatter.

  Action dispatch is driven by the string `action` param. Successful
  responses always echo a `current` map (`brain_id`, `brain_title`,
  `page_id`, `page_title`) so the LLM knows where it is between calls
  without re-reading the world.

  All body writes go through `Magus.Brain.update_page_body/3` which
  enforces optimistic concurrency via the `lock_version` column. On
  conflict (`Magus.Brain.Page.Errors.VersionConflict`) the per-action
  retry protocol kicks in — see the action-specific notes inside.

  This module is a thin dispatcher: the schema, valid actions, and
  removed-action stubs live here, but each action's handler logic lives
  in a concern submodule under `EditBrain.*`:

    * `EditBrain.PageContent` — write_page, edit_page, multi_edit,
      clear_page, undo_last_edit (page BODY content)
    * `EditBrain.Structure` — create_brain, rename_page, move_page,
      delete_page (brain/page STRUCTURE)
    * `EditBrain.Support` — shared internals both submodules use (the
      `current` echo, page lookup, the lock-conflict retry protocol,
      the diff renderer)
  """

  use Jido.Action,
    name: "edit_brain",
    description: """
    Edit your knowledge brain. Pages are markdown documents — write,
    edit, clear like files. Links via `[[Page Name]]`. Tags via `#tag` or
    `tags:` in YAML frontmatter. This tool handles WRITES only; to read
    page or source content use the `read_brain` tool (read_page, peek_page,
    read_source).

    Actions:
    - create_brain: New brain. Required: title. Optional: description, icon.
    - write_page: Create or modify a page body. Required: title (or page_id),
      body. mode: "create" (default for brand new pages) | "replace" |
      "append" | "prepend". When a page already exists at the same title,
      mode is REQUIRED — the response will list the existing page id + a
      body preview so you can decide. Slash-paths ("Parent/Child") auto-
      create ancestor pages. To nest a NEW page under a specific parent
      unambiguously, pass parent_page_id (the page id, taken from the tree
      context). If the same title exists at multiple locations and no
      parent_page_id is given, the call returns an ambiguity error listing
      the candidate page ids — re-issue with parent_page_id (preferred) or a
      slash-path.
    - edit_page: Targeted body edit. Twin modes:
      (1) String: required old_str + new_str. Optional replace_all (default
          false) and hint_line.
      (2) Line-range: required start_line + end_line + new_content. Use
          end_line == start_line - 1 to PURE-INSERT before start_line.
      Required one of: page_id, page_title.
    - multi_edit: Apply N edits to one page in a single save. Required:
      page_id, edits (non-empty list). Each edit is either string mode
      (old_str + new_str, optional replace_all) OR line-range mode
      (start_line + end_line + new_content). Edits run sequentially top-
      down; each sees the buffer left by the previous edit. All-or-nothing:
      if any edit fails the whole call returns an error pointing at the
      failing index and NOTHING is saved.
    - clear_page: Reset body to empty string. Required: page_id.
    - undo_last_edit: Restore the page body to its prior version. Required:
      page_id.
    - rename_page: Required: page_id, title.
    - move_page: Required: page_id. Optional: parent_page_id (nil = root).
    - delete_page: Required: page_id. Moves to trash (30-day restore window).

    Removed actions (use the replacements above): add_block, edit_block,
    delete_block, move_block, link.

    Concurrency: writes use optimistic locking. On a stale base_version,
    write_page :replace/:append/:prepend and edit_page string mode retry
    once. edit_page line-range mode does NOT auto-retry (line numbers may
    have shifted); the conflict is surfaced with the new body.
    """,
    schema: [
      action: [type: :string, required: true, doc: "Action to perform"],
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
      parent_page_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc:
          "Parent page ID. For move_page (new parent; null = root) and write_page (create the new page under this parent)."
      ],
      title: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Title for create_brain / write_page / rename_page"
      ],
      body: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Markdown body for write_page"
      ],
      mode: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "write_page mode: create | replace | append | prepend"
      ],
      description: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Description for create_brain"
      ],
      icon: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Icon for create_brain"
      ],
      old_str: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "edit_page string mode: text to find"
      ],
      new_str: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "edit_page string mode: replacement text"
      ],
      replace_all: [
        type: {:or, [:boolean, nil]},
        default: nil,
        doc: "edit_page string mode: replace all occurrences (default false)"
      ],
      hint_line: [
        type: {:or, [:integer, nil]},
        default: nil,
        doc: "edit_page string mode: optional line hint for error messages"
      ],
      start_line: [
        type: {:or, [:integer, nil]},
        default: nil,
        doc: "Line-range mode start (1-indexed, inclusive)"
      ],
      end_line: [
        type: {:or, [:integer, nil]},
        default: nil,
        doc: "Line-range mode end (1-indexed, inclusive); use start_line - 1 to insert"
      ],
      new_content: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "edit_page line-range mode: replacement content"
      ],
      edits: [
        type: {:or, [{:list, :map}, nil]},
        default: nil,
        doc:
          "multi_edit: non-empty list of edit maps. Each map is string mode (old_str + new_str, optional replace_all) OR line-range mode (start_line + end_line + new_content)."
      ]
    ]

  alias Magus.Agents.Tools.Brain.EditBrain.PageContent
  alias Magus.Agents.Tools.Brain.EditBrain.Structure

  import Magus.Agents.Tools.Helpers,
    only: [validate_context: 2, get_param: 2, nilify_blank_params: 2]

  @valid_actions ~w(create_brain write_page edit_page
                    multi_edit clear_page undo_last_edit
                    rename_page move_page delete_page
                    add_block edit_block delete_block move_block link)

  def display_name, do: "Editing brain..."

  def summarize_output(%{error: error}) when is_binary(error), do: "Error: #{error}"
  def summarize_output(%{action: "create_brain", brain_title: t}), do: "Created brain: #{t}"
  def summarize_output(%{action: "write_page", mode: m, page_title: t}), do: "#{m} page: #{t}"

  def summarize_output(%{action: "edit_page", page_title: t, mode: m}),
    do: "Edited (#{m}): #{t}"

  def summarize_output(%{action: "clear_page", page_title: t}), do: "Cleared: #{t}"
  def summarize_output(%{action: "undo_last_edit", page_title: t}), do: "Undid edit on: #{t}"
  def summarize_output(%{action: "rename_page", page_title: t}), do: "Renamed to: #{t}"
  def summarize_output(%{action: "move_page"}), do: "Page moved"
  def summarize_output(%{action: "delete_page"}), do: "Page moved to trash"
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
    valid = Enum.join(@valid_actions -- removed_actions(), ", ")

    if is_nil(action) do
      {:ok, %{error: "Missing required parameter: action. Must be one of: #{valid}"}}
    else
      {:ok, %{error: "Unknown action '#{action}'. Must be one of: #{valid}"}}
    end
  end

  # Removed-action stubs return a helpful migration hint.
  defp dispatch("add_block", _params, _ctx, _context) do
    {:ok,
     %{
       error:
         "add_block was removed. Use `write_page` with mode \"append\" to add content to the end of a page, or `edit_page` (line-range mode with end_line == start_line - 1) to insert at a specific line."
     }}
  end

  defp dispatch("edit_block", _params, _ctx, _context) do
    {:ok,
     %{
       error:
         "edit_block was removed. Use `edit_page` with old_str/new_str for a targeted text replacement, or with start_line/end_line/new_content for a line-range replacement."
     }}
  end

  defp dispatch("delete_block", _params, _ctx, _context) do
    {:ok,
     %{
       error:
         "delete_block was removed. Use `edit_page` with start_line/end_line and an empty new_content to delete a range of lines."
     }}
  end

  defp dispatch("move_block", _params, _ctx, _context) do
    {:ok,
     %{
       error:
         "move_block was removed. Use `edit_page` to delete the lines from the source page, then `write_page` with mode \"append\" to add them to the target page."
     }}
  end

  defp dispatch("link", _params, _ctx, _context) do
    {:ok,
     %{
       error:
         "link was removed. Add `[[Page Name]]` to the body of the linking page (use `edit_page` to insert it). Backlinks are derived automatically."
     }}
  end

  # ---------------------------------------------------------------------------
  # Structure actions -> EditBrain.Structure
  # ---------------------------------------------------------------------------

  defp dispatch("create_brain", params, ctx, context) do
    Structure.handle_create_brain(params, ctx, context)
  end

  defp dispatch("rename_page", params, ctx, context) do
    Structure.handle_rename_page(params, ctx, context)
  end

  defp dispatch("delete_page", params, ctx, context) do
    Structure.handle_delete_page(params, ctx, context)
  end

  defp dispatch("move_page", params, ctx, context) do
    Structure.handle_move_page(params, ctx, context)
  end

  # ---------------------------------------------------------------------------
  # Page-content actions -> EditBrain.PageContent
  # ---------------------------------------------------------------------------

  defp dispatch("write_page", params, ctx, context) do
    PageContent.handle_write_page(params, ctx, context)
  end

  defp dispatch("edit_page", params, ctx, context) do
    PageContent.handle_edit_page(params, ctx, context)
  end

  defp dispatch("multi_edit", params, ctx, context) do
    PageContent.handle_multi_edit(params, ctx, context)
  end

  defp dispatch("clear_page", params, ctx, context) do
    PageContent.handle_clear_page(params, ctx, context)
  end

  defp dispatch("undo_last_edit", params, ctx, context) do
    PageContent.handle_undo_last_edit(params, ctx, context)
  end

  defp removed_actions, do: ~w(add_block edit_block delete_block move_block link)
end
