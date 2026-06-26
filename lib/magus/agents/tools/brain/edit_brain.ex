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

  require Logger
  require Ash.Query

  alias Magus.Brain
  alias Magus.Brain.Page.Errors.VersionConflict
  alias Magus.Agents.Tools.Brain.BrainResolver
  alias Magus.Agents.Signals

  import Magus.Agents.Tools.Helpers,
    only: [validate_context: 2, get_param: 2, tool_error: 3]

  @valid_actions ~w(create_brain write_page edit_page
                    multi_edit clear_page undo_last_edit
                    rename_page move_page delete_page
                    add_block edit_block delete_block move_block link)

  @write_modes ~w(create replace append prepend)

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
  # create_brain (unchanged behavior)
  # ---------------------------------------------------------------------------

  defp dispatch("create_brain", params, ctx, context) do
    title = get_param(params, :title)

    if blank?(title) do
      {:ok, %{error: "Missing required parameter: title"}}
    else
      attrs = %{title: title}

      attrs =
        if d = get_param(params, :description), do: Map.put(attrs, :description, d), else: attrs

      attrs = if i = get_param(params, :icon), do: Map.put(attrs, :icon, i), else: attrs

      attrs =
        case Map.get(context, :workspace_id) do
          nil -> attrs
          ws_id -> Map.put(attrs, :workspace_id, ws_id)
        end

      case Brain.create_brain(attrs, actor: ctx.user) do
        {:ok, brain} ->
          Magus.FeatureUsage.track(ctx.user_id, "brains", "create")

          {:ok,
           %{
             action: "create_brain",
             brain_id: brain.id,
             brain_title: brain.title,
             current: build_current(brain, nil),
             hint: "Brain '#{brain.title}' created. Use write_page to add the first page."
           }}

        {:error, err} ->
          {:ok,
           %{
             error:
               tool_error(
                 "create brain",
                 err,
                 "Check the title is non-empty and the actor has permission."
               )
           }}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # write_page
  # ---------------------------------------------------------------------------

  defp dispatch("write_page", params, ctx, context) do
    body = get_param(params, :body) || ""
    mode = normalize_mode(get_param(params, :mode))
    explicit_page_id = get_param(params, :page_id)
    title = get_param(params, :title)

    cond do
      mode == :invalid ->
        {:ok,
         %{
           error:
             "Invalid mode '#{get_param(params, :mode)}'. Must be one of: create, replace, append, prepend."
         }}

      not is_nil(explicit_page_id) ->
        with {:ok, page} <- Brain.get_page(explicit_page_id, actor: ctx.user) do
          do_write_existing_page(page, body, mode || :replace, ctx, context)
        else
          {:error, err} ->
            {:ok,
             %{
               error: tool_error("write page", err, "Verify page_id with read_brain list_pages.")
             }}
        end

      blank?(title) ->
        {:ok, %{error: "Missing required parameter: title (or page_id)"}}

      true ->
        case BrainResolver.resolve_brain_id(context, params) do
          {:ok, brain_id} ->
            parent_page_id = get_param(params, :parent_page_id)

            resolve_and_write_by_title(
              brain_id,
              title,
              body,
              mode,
              parent_page_id,
              ctx,
              context
            )

          {:error, msg} ->
            {:ok, %{error: msg}}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # edit_page
  # ---------------------------------------------------------------------------

  defp dispatch("edit_page", params, ctx, context) do
    with {:ok, brain_id} <- BrainResolver.resolve_brain_id(context, params),
         {:ok, page} <- resolve_page_for_read(context, params, brain_id, ctx) do
      old_str = get_param(params, :old_str)
      new_str = get_param(params, :new_str)
      start_line = get_param(params, :start_line)
      end_line = get_param(params, :end_line)
      new_content = get_param(params, :new_content)

      cond do
        not is_nil(old_str) ->
          replace_all = get_param(params, :replace_all) == true
          hint_line = get_param(params, :hint_line)
          do_edit_string(page, old_str, new_str || "", replace_all, hint_line, ctx)

        not is_nil(start_line) and not is_nil(end_line) ->
          do_edit_line_range(page, start_line, end_line, new_content || "", ctx)

        true ->
          {:ok,
           %{
             error:
               "Provide either old_str + new_str (string mode) or start_line + end_line + new_content (line-range mode)."
           }}
      end
    else
      {:error, msg} when is_binary(msg) -> {:ok, %{error: msg}}
      {:error, err} -> {:ok, %{error: tool_error("edit page", err, nil)}}
    end
  end

  # ---------------------------------------------------------------------------
  # multi_edit
  # ---------------------------------------------------------------------------

  defp dispatch("multi_edit", params, ctx, _context) do
    page_id = get_param(params, :page_id)
    edits = get_param(params, :edits)

    cond do
      is_nil(page_id) ->
        {:ok, %{error: "Missing required parameter: page_id"}}

      not is_list(edits) or edits == [] ->
        {:ok, %{error: "Missing or empty required parameter: edits (non-empty list)"}}

      true ->
        case Brain.get_page(page_id, actor: ctx.user) do
          {:ok, page} ->
            do_multi_edit(page, edits, ctx)

          {:error, err} ->
            {:ok,
             %{
               error:
                 tool_error(
                   "multi_edit",
                   err,
                   "Verify page_id with read_brain list_pages."
                 )
             }}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # clear_page
  # ---------------------------------------------------------------------------

  defp dispatch("clear_page", params, ctx, _context) do
    page_id = get_param(params, :page_id)

    if is_nil(page_id) do
      {:ok, %{error: "Missing required parameter: page_id"}}
    else
      with {:ok, page} <- Brain.get_page(page_id, actor: ctx.user),
           {:ok, updated} <- save_body_with_retry(page, "", :clear, ctx) do
        brain = load_brain(updated, ctx)

        {:ok,
         %{
           action: "clear_page",
           cleared: true,
           page_id: updated.id,
           page_title: updated.title,
           current: build_current(brain, updated)
         }}
      else
        {:error, %VersionConflict{} = conflict} ->
          {:ok, conflict_payload("clear page", conflict, page_id, ctx)}

        {:error, err} ->
          {:ok,
           %{
             error: tool_error("clear page", err, "Verify page_id with read_brain list_pages.")
           }}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # undo_last_edit
  # ---------------------------------------------------------------------------

  defp dispatch("undo_last_edit", params, ctx, _context) do
    page_id = get_param(params, :page_id)

    if is_nil(page_id) do
      {:ok, %{error: "Missing required parameter: page_id"}}
    else
      do_undo_last_edit(page_id, ctx)
    end
  end

  # ---------------------------------------------------------------------------
  # rename_page / move_page / delete_page (preserved)
  # ---------------------------------------------------------------------------

  defp dispatch("rename_page", params, ctx, _context) do
    page_id = get_param(params, :page_id)
    title = get_param(params, :title)

    cond do
      is_nil(page_id) ->
        {:ok, %{error: "Missing required parameter: page_id"}}

      blank?(title) ->
        {:ok, %{error: "Missing required parameter: title"}}

      true ->
        with {:ok, page} <- Brain.get_page(page_id, actor: ctx.user),
             {:ok, updated} <- Brain.update_page_title(page, %{title: title}, actor: ctx.user) do
          brain = load_brain(updated, ctx)

          {:ok,
           %{
             action: "rename_page",
             page_id: updated.id,
             page_title: updated.title,
             current: build_current(brain, updated),
             hint: "Renamed to '#{updated.title}'."
           }}
        else
          {:error, err} ->
            {:ok,
             %{
               error: tool_error("rename page", err, "Verify page_id with read_brain list_pages.")
             }}
        end
    end
  end

  defp dispatch("delete_page", params, ctx, _context) do
    page_id = get_param(params, :page_id)

    if is_nil(page_id) do
      {:ok, %{error: "Missing required parameter: page_id"}}
    else
      with {:ok, page} <- Brain.get_page(page_id, actor: ctx.user),
           descendant_count = count_descendants(page_id, ctx),
           {:ok, _trashed} <- Brain.soft_delete_page(page, actor: ctx.user) do
        hint =
          if descendant_count > 0 do
            "Moved page and #{descendant_count} sub-page(s) to trash. The user can restore within 30 days."
          else
            "Moved page to trash. The user can restore within 30 days."
          end

        {:ok, %{action: "delete_page", page_id: page_id, hint: hint}}
      else
        {:error, err} ->
          {:ok,
           %{
             error: tool_error("delete page", err, "Verify page_id with read_brain list_pages.")
           }}
      end
    end
  end

  defp dispatch("move_page", params, ctx, _context) do
    page_id = get_param(params, :page_id)
    parent_page_id = get_param(params, :parent_page_id)

    if is_nil(page_id) do
      {:ok, %{error: "Missing required parameter: page_id"}}
    else
      with {:ok, page} <- Brain.get_page(page_id, actor: ctx.user),
           {:ok, moved} <-
             Brain.move_page_to_parent(page, %{parent_page_id: parent_page_id}, actor: ctx.user) do
        {:ok, reloaded} = Brain.get_page(moved.id, actor: ctx.user)
        brain = load_brain(reloaded, ctx)

        {:ok,
         %{
           action: "move_page",
           page_id: reloaded.id,
           parent_page_id: reloaded.parent_page_id,
           depth: reloaded.depth,
           current: build_current(brain, reloaded),
           hint: "Page moved."
         }}
      else
        {:error, err} ->
          {:ok,
           %{
             error:
               tool_error(
                 "move page",
                 err,
                 "Verify page_id and parent_page_id (pass null for root)."
               )
           }}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # write_page helpers
  # ---------------------------------------------------------------------------

  defp resolve_and_write_by_title(brain_id, title, body, mode, parent_page_id, ctx, context) do
    cond do
      slash_path?(title) ->
        # Slash-paths route through Writer for ancestor creation. For
        # collisions on the leaf, fall through to the collision branch
        # only when mode wasn't supplied; otherwise let Writer handle it.
        do_write_via_slash_path(brain_id, title, body, mode, ctx, context)

      not is_nil(parent_page_id) ->
        write_under_parent(brain_id, title, body, mode, parent_page_id, ctx, context)

      true ->
        # Bare title, no explicit parent. Look up ALL pages with this title in
        # the brain so we can disambiguate when the title is not unique.
        case Brain.find_page_by_title(brain_id, title, actor: ctx.user) do
          {:ok, [page]} ->
            collision_or_write(page, title, body, mode, ctx, context)

          {:ok, [_, _ | _] = pages} ->
            # More than one page shares this title at different locations.
            # Refuse to silently pick one — surface the candidates so the
            # agent can re-issue with parent_page_id or a slash-path.
            {:ok, ambiguous_parent_payload(pages, title, ctx)}

          {:ok, []} ->
            # No collision: default to :create when no mode supplied.
            do_create_page(brain_id, title, body, mode || :create, ctx, context)

          _ ->
            # Lenient fallback (preserves prior behavior): treat lookup errors
            # as "no existing page" and create at root.
            do_create_page(brain_id, title, body, mode || :create, ctx, context)
        end
    end
  end

  # Resolve a write when an explicit parent_page_id is supplied. The parent
  # MUST exist and belong to the same brain; otherwise we refuse rather than
  # silently creating at the root.
  defp write_under_parent(brain_id, title, body, mode, parent_page_id, ctx, context) do
    case Brain.get_page(parent_page_id, actor: ctx.user) do
      {:ok, %{brain_id: ^brain_id}} ->
        case existing_at_parent(brain_id, title, parent_page_id, ctx) do
          {:ok, page} ->
            collision_or_write(page, title, body, mode, ctx, context)

          :not_found ->
            do_create_page_under(
              brain_id,
              title,
              body,
              mode || :create,
              parent_page_id,
              ctx,
              context
            )
        end

      _ ->
        {:ok, %{error: "parent_page_id #{parent_page_id} is not a page in this brain."}}
    end
  end

  # Shared collision handling for an EXISTING page found by title (bare or
  # parent-scoped). Preserves the exact prior semantics: missing mode → ask for
  # a mode; :create → refuse to overwrite; otherwise apply the write.
  defp collision_or_write(page, title, body, mode, ctx, context) do
    brain_id = page.brain_id

    cond do
      is_nil(mode) ->
        emit_collision_telemetry(brain_id, page.id, page.title, nil)
        {:ok, mode_required_payload(page, ctx)}

      mode == :create ->
        emit_collision_telemetry(brain_id, page.id, page.title, :create)

        {:ok,
         %{
           error:
             "Page '#{title}' already exists. mode 'create' refuses to overwrite. Use 'replace', 'append', or 'prepend'."
         }}

      true ->
        do_write_existing_page(page, body, mode, ctx, context)
    end
  end

  defp ambiguous_parent_payload(pages, title, ctx) do
    %{
      error:
        "Multiple pages titled '#{title}' exist at different locations. Disambiguate by passing parent_page_id (preferred) or a slash-path 'Parent/#{title}'.",
      candidates:
        Enum.map(pages, fn p ->
          %{page_id: p.id, breadcrumb: build_breadcrumb(p, ctx)}
        end)
    }
  end

  defp do_write_via_slash_path(brain_id, title_path, body, mode, ctx, context) do
    # When mode is missing AND the leaf already exists, we need to do the
    # same collision flow as bare titles. Walk the chain manually to look
    # up the leaf.
    segments = parse_slash(title_path)
    leaf_title = List.last(segments)

    case resolve_leaf_via_chain(brain_id, segments, ctx) do
      {:ok, page} ->
        cond do
          is_nil(mode) ->
            emit_collision_telemetry(brain_id, page.id, page.title, nil)
            {:ok, mode_required_payload(page, ctx)}

          mode == :create ->
            emit_collision_telemetry(brain_id, page.id, page.title, :create)

            {:ok,
             %{
               error:
                 "Page '#{leaf_title}' already exists at this slash-path. mode 'create' refuses to overwrite."
             }}

          true ->
            do_write_existing_page(page, body, mode, ctx, context)
        end

      :not_found ->
        cleaned = strip_rogue_title_heading(body, leaf_title)

        case find_or_create_chain(brain_id, segments, ctx) do
          {:ok, page} ->
            do_write_existing_page(page, cleaned, mode || :create, ctx, context,
              fresh_create?: true
            )

          {:error, :invalid_title} ->
            {:ok, %{error: "Missing required parameter: title"}}

          {:error, err} ->
            {:ok,
             %{
               error:
                 tool_error(
                   "write page (slash-path)",
                   err,
                   "Verify the path segments and that the brain is accessible."
                 )
             }}
        end
    end
  end

  defp do_create_page(brain_id, title, body, mode, ctx, context)
       when mode in [:create, :append, :replace, :prepend] do
    cleaned = strip_rogue_title_heading(body, title)

    case create_leaf_page(brain_id, title, nil, ctx) do
      {:ok, page} ->
        do_write_existing_page(page, cleaned, mode, ctx, context, fresh_create?: true)

      {:error, :invalid_title} ->
        {:ok, %{error: "Missing required parameter: title"}}

      {:error, :already_exists} ->
        case find_existing_page(brain_id, title, ctx) do
          {:ok, page} ->
            emit_collision_telemetry(brain_id, page.id, page.title, mode)
            {:ok, mode_required_payload(page, ctx)}

          :not_found ->
            {:ok, %{error: "Page race resolution failed. Try again."}}
        end

      {:error, err} ->
        {:ok,
         %{
           error: tool_error("write page", err, "Verify brain_id with read_brain list_brains.")
         }}
    end
  end

  # Mirror of do_create_page/6 but creates the new page UNDER an explicit
  # parent (parent existence + same-brain check already done by the caller).
  defp do_create_page_under(brain_id, title, body, mode, parent_page_id, ctx, context)
       when mode in [:create, :append, :replace, :prepend] do
    cleaned = strip_rogue_title_heading(body, title)

    case create_leaf_page(brain_id, title, parent_page_id, ctx) do
      {:ok, page} ->
        do_write_existing_page(page, cleaned, mode, ctx, context, fresh_create?: true)

      {:error, :invalid_title} ->
        {:ok, %{error: "Missing required parameter: title"}}

      {:error, :already_exists} ->
        case existing_at_parent(brain_id, title, parent_page_id, ctx) do
          {:ok, page} ->
            emit_collision_telemetry(brain_id, page.id, page.title, mode)
            {:ok, mode_required_payload(page, ctx)}

          :not_found ->
            {:ok, %{error: "Page race resolution failed. Try again."}}
        end

      {:error, err} ->
        {:ok,
         %{
           error: tool_error("write page", err, "Verify brain_id with read_brain list_brains.")
         }}
    end
  end

  defp do_write_existing_page(page, body, mode, ctx, context, opts \\ []) do
    fresh? = Keyword.get(opts, :fresh_create?, false)
    cleaned = strip_rogue_title_heading(body, page.title)

    next_body =
      case mode do
        :create when not fresh? ->
          nil

        :replace ->
          cleaned

        :append ->
          combine_append(page.body, cleaned)

        :prepend ->
          combine_prepend(page.body, cleaned)

        :create ->
          cleaned
      end

    if is_nil(next_body) do
      {:ok,
       %{
         error:
           "Page '#{page.title}' already exists. mode 'create' refuses to overwrite. Use 'replace', 'append', or 'prepend'."
       }}
    else
      mode_label =
        cond do
          fresh? -> "create"
          true -> Atom.to_string(mode)
        end

      case save_body_with_retry(page, next_body, retry_kind_for_write(mode), ctx) do
        {:ok, updated} ->
          brain = load_brain(updated, ctx)
          maybe_open_brain_pane(context, brain.id, updated.id)

          {:ok,
           %{
             action: "write_page",
             page_id: updated.id,
             page_title: updated.title,
             mode: mode_label,
             current: build_current(brain, updated)
           }}

        {:error, %VersionConflict{} = conflict} ->
          {:ok, conflict_payload("write page (#{mode_label})", conflict, page.id, ctx)}

        {:error, err} ->
          {:ok,
           %{
             error:
               tool_error(
                 "write page",
                 err,
                 "The page write was rejected by the database. Re-read the page and retry."
               )
           }}
      end
    end
  end

  defp retry_kind_for_write(:append), do: :write_append
  defp retry_kind_for_write(:prepend), do: :write_prepend
  defp retry_kind_for_write(:replace), do: :write_replace
  defp retry_kind_for_write(:create), do: :write_create

  defp combine_append(nil, addition), do: addition
  defp combine_append("", addition), do: addition
  defp combine_append(existing, ""), do: existing

  defp combine_append(existing, addition) do
    String.trim_trailing(existing) <> "\n\n" <> String.trim_leading(addition)
  end

  defp combine_prepend(nil, addition), do: addition
  defp combine_prepend("", addition), do: addition
  defp combine_prepend(existing, ""), do: existing

  defp combine_prepend(existing, addition) do
    String.trim_trailing(addition) <> "\n\n" <> String.trim_leading(existing)
  end

  # Strip an exact rogue leading `# {title}` heading so we never duplicate
  # the page title inside the body. Leaves a non-matching H1 (different
  # text) alone.
  defp strip_rogue_title_heading(body, _title) when body in [nil, ""], do: body || ""

  defp strip_rogue_title_heading(body, title) when is_binary(body) and is_binary(title) do
    trimmed = String.trim_leading(body)
    target = "# " <> title

    cond do
      String.starts_with?(trimmed, target <> "\n") ->
        rest = String.replace_prefix(trimmed, target <> "\n", "")
        String.trim_leading(rest)

      trimmed == target ->
        ""

      true ->
        body
    end
  end

  defp strip_rogue_title_heading(body, _title), do: body

  defp normalize_mode(nil), do: nil

  defp normalize_mode(mode) when is_binary(mode) do
    case String.downcase(mode) do
      m when m in @write_modes -> String.to_existing_atom(m)
      _ -> :invalid
    end
  end

  defp normalize_mode(_), do: :invalid

  defp mode_required_payload(page, ctx) do
    body = page.body || ""

    %{
      error:
        "Page '#{page.title}' already exists. mode is REQUIRED — use 'replace', 'append', 'prepend', or pick a different title.",
      existing_page_id: page.id,
      existing_page_title: page.title,
      body_preview: String.slice(body, 0, 200),
      last_modified_at: page.updated_at,
      current: build_current(load_brain(page, ctx), page)
    }
  end

  defp find_existing_page(brain_id, title, ctx) do
    case Brain.find_page_by_title(brain_id, title, actor: ctx.user) do
      {:ok, [page | _]} -> {:ok, page}
      {:ok, []} -> :not_found
      _ -> :not_found
    end
  end

  defp parse_slash(path) do
    path
    |> String.split("/")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp slash_path?(title) when is_binary(title) do
    title |> parse_slash() |> length() |> Kernel.>(1)
  end

  defp slash_path?(_), do: false

  defp resolve_leaf_via_chain(brain_id, segments, ctx) do
    walk_segments(brain_id, segments, nil, ctx)
  end

  defp walk_segments(_brain_id, [], _parent, _ctx), do: :not_found

  defp walk_segments(brain_id, [last], parent_id, ctx) do
    case Brain.find_page_by_title(brain_id, last, actor: ctx.user) do
      {:ok, pages} ->
        case Enum.find(pages, fn p -> p.parent_page_id == parent_id end) do
          nil -> :not_found
          page -> {:ok, page}
        end

      _ ->
        :not_found
    end
  end

  defp walk_segments(brain_id, [head | rest], parent_id, ctx) do
    case Brain.find_page_by_title(brain_id, head, actor: ctx.user) do
      {:ok, pages} ->
        case Enum.find(pages, fn p -> p.parent_page_id == parent_id end) do
          nil -> :not_found
          page -> walk_segments(brain_id, rest, page.id, ctx)
        end

      _ ->
        :not_found
    end
  end

  # Walks a slash-path's segments, creating any missing ancestor pages
  # (with empty body) and the leaf. Returns the leaf page. Any segment
  # that already exists at the right parent is reused as-is.
  defp find_or_create_chain(_brain_id, [], _ctx), do: {:error, :invalid_title}

  defp find_or_create_chain(brain_id, segments, ctx) do
    do_find_or_create_chain(brain_id, segments, nil, ctx)
  end

  defp do_find_or_create_chain(brain_id, [leaf], parent_id, ctx) do
    create_leaf_page(brain_id, leaf, parent_id, ctx)
  end

  defp do_find_or_create_chain(brain_id, [head | rest], parent_id, ctx) do
    case existing_at_parent(brain_id, head, parent_id, ctx) do
      {:ok, page} ->
        do_find_or_create_chain(brain_id, rest, page.id, ctx)

      :not_found ->
        case create_leaf_page(brain_id, head, parent_id, ctx) do
          {:ok, page} -> do_find_or_create_chain(brain_id, rest, page.id, ctx)
          err -> err
        end
    end
  end

  defp existing_at_parent(brain_id, title, parent_id, ctx) do
    case Brain.find_page_by_title(brain_id, title, actor: ctx.user) do
      {:ok, pages} ->
        case Enum.find(pages, fn p -> p.parent_page_id == parent_id end) do
          nil -> :not_found
          page -> {:ok, page}
        end

      _ ->
        :not_found
    end
  end

  defp create_leaf_page(_brain_id, title, _parent_id, _ctx)
       when not is_binary(title) or title == "",
       do: {:error, :invalid_title}

  defp create_leaf_page(brain_id, title, parent_id, ctx) do
    attrs = %{title: title} |> maybe_put(:parent_page_id, parent_id)

    case Brain.create_page(brain_id, attrs, actor: ctx.user) do
      {:ok, page} -> {:ok, page}
      {:error, err} -> {:error, err}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ---------------------------------------------------------------------------
  # edit_page — string mode
  # ---------------------------------------------------------------------------

  defp do_edit_string(page, old_str, new_str, replace_all, hint_line, ctx) do
    do_edit_string_attempt(page, old_str, new_str, replace_all, hint_line, ctx, false)
  end

  defp do_edit_string_attempt(page, old_str, new_str, replace_all, hint_line, ctx, retried?) do
    body = page.body || ""
    occurrences = count_occurrences(body, old_str)

    cond do
      occurrences == 0 ->
        emit_edit_miss_telemetry(page.brain_id, page.id, old_str)

        hint_msg =
          if is_integer(hint_line),
            do: " You hinted line #{hint_line}; check the page content at that location.",
            else: ""

        {:ok,
         %{
           error: "old_str not found on page '#{page.title}'.#{hint_msg}",
           page_id: page.id,
           current: build_current(load_brain(page, ctx), page)
         }}

      occurrences > 1 and not replace_all ->
        emit_edit_ambiguous_telemetry(page.brain_id, page.id, occurrences, replace_all)
        positions = find_line_numbers(body, old_str)

        {:ok,
         %{
           error:
             "old_str appears #{occurrences} times on page '#{page.title}' (lines #{Enum.join(positions, ", ")}). Provide more surrounding context to make it unique, or set replace_all to true.",
           occurrences: occurrences,
           page_id: page.id,
           current: build_current(load_brain(page, ctx), page)
         }}

      true ->
        new_body =
          if replace_all do
            String.replace(body, old_str, new_str)
          else
            String.replace(body, old_str, new_str, global: false)
          end

        case save_body_with_retry(page, new_body, :edit_string, ctx) do
          {:ok, updated} ->
            brain = load_brain(updated, ctx)
            diff = build_unified_diff(body, new_body, updated.title)

            {:ok,
             %{
               action: "edit_page",
               mode: "string",
               page_id: updated.id,
               page_title: updated.title,
               replacements: if(replace_all, do: occurrences, else: 1),
               diff: diff,
               current: build_current(brain, updated)
             }}

          {:error, %VersionConflict{current_body: latest_body, current_version: cv}}
          when not retried? ->
            emit_lock_conflict_telemetry(:edit_string, :retried)
            # Rebuild page record with latest body + version so the retry
            # operates on the up-to-date snapshot.
            refreshed = %{page | body: latest_body, lock_version: cv}
            do_edit_string_attempt(refreshed, old_str, new_str, replace_all, hint_line, ctx, true)

          {:error, %VersionConflict{} = conflict} ->
            emit_lock_conflict_telemetry(:edit_string, :surrendered)
            {:ok, conflict_payload("edit page (string)", conflict, page.id, ctx)}

          {:error, err} ->
            {:ok,
             %{
               error:
                 tool_error("edit page", err, "Re-read the page and retry with updated old_str.")
             }}
        end
    end
  end

  defp find_line_numbers(body, needle) do
    body
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> String.contains?(line, needle) end)
    |> Enum.map(fn {_, idx} -> idx end)
  end

  # ---------------------------------------------------------------------------
  # edit_page — line-range mode
  # ---------------------------------------------------------------------------

  defp do_edit_line_range(page, start_line, end_line, new_content, ctx) do
    body = page.body || ""
    lines = String.split(body, "\n")
    total = length(lines)

    cond do
      start_line < 1 ->
        {:ok, %{error: "start_line must be >= 1, got #{start_line}."}}

      end_line < start_line - 1 ->
        {:ok,
         %{
           error:
             "end_line (#{end_line}) must be >= start_line - 1 (#{start_line - 1}) for pure insertion, or >= start_line (#{start_line}) for replacement."
         }}

      start_line > total + 1 ->
        {:ok, %{error: "start_line #{start_line} exceeds body length (#{total} lines)."}}

      end_line > total ->
        {:ok, %{error: "end_line #{end_line} exceeds body length (#{total} lines)."}}

      true ->
        # end_line == start_line - 1 means pure insertion before start_line.
        before = Enum.take(lines, start_line - 1)

        after_lines =
          if end_line < start_line do
            Enum.drop(lines, start_line - 1)
          else
            Enum.drop(lines, end_line)
          end

        new_lines = String.split(new_content, "\n")

        merged =
          cond do
            new_content == "" and end_line >= start_line ->
              # Pure deletion: drop the range entirely without adding an empty line.
              before ++ after_lines

            true ->
              before ++ new_lines ++ after_lines
          end

        new_body = Enum.join(merged, "\n")

        case save_body_with_retry(page, new_body, :edit_line_range, ctx) do
          {:ok, updated} ->
            brain = load_brain(updated, ctx)
            diff = build_unified_diff(body, new_body, updated.title)

            {:ok,
             %{
               action: "edit_page",
               mode: "line_range",
               page_id: updated.id,
               page_title: updated.title,
               lines_replaced: "#{start_line}-#{end_line}",
               diff: diff,
               current: build_current(brain, updated)
             }}

          {:error, %VersionConflict{} = conflict} ->
            emit_lock_conflict_telemetry(:edit_line_range, :surrendered)
            {:ok, conflict_payload("edit page (line-range)", conflict, page.id, ctx)}

          {:error, err} ->
            {:ok,
             %{
               error:
                 tool_error(
                   "edit page",
                   err,
                   "Re-read the page; line numbers may have shifted."
                 )
             }}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # multi_edit — sequential pure edits, one save
  # ---------------------------------------------------------------------------

  defp do_multi_edit(page, edits, ctx) do
    original_body = page.body || ""

    case apply_edits(original_body, edits, 0, []) do
      {:ok, new_body, applied} ->
        case save_body_with_retry(page, new_body, :multi_edit, ctx) do
          {:ok, updated} ->
            brain = load_brain(updated, ctx)
            diff = build_unified_diff(original_body, new_body, updated.title)

            {:ok,
             %{
               action: "multi_edit",
               page_id: updated.id,
               page_title: updated.title,
               edits_applied: length(applied),
               applied: Enum.reverse(applied),
               diff: diff,
               current: build_current(brain, updated)
             }}

          {:error, %VersionConflict{} = conflict} ->
            {:ok, conflict_payload("multi_edit", conflict, page.id, ctx)}

          {:error, err} ->
            {:ok,
             %{
               error:
                 tool_error(
                   "multi_edit",
                   err,
                   "Re-read the page; line numbers may have shifted."
                 )
             }}
        end

      {:error, idx, reason} ->
        {:ok,
         %{
           error: "edit ##{idx} failed: #{reason}. No changes saved.",
           failed_edit_index: idx,
           page_id: page.id,
           current: build_current(load_brain(page, ctx), page)
         }}
    end
  end

  defp apply_edits(body, [], _idx, applied), do: {:ok, body, applied}

  defp apply_edits(body, [edit | rest], idx, applied) do
    case apply_single_edit(body, edit) do
      {:ok, new_body, summary} ->
        apply_edits(new_body, rest, idx + 1, [Map.put(summary, :index, idx) | applied])

      {:error, reason} ->
        {:error, idx, reason}
    end
  end

  defp apply_single_edit(body, edit) when is_map(edit) do
    has_string_mode = not is_nil(edit_value(edit, :old_str))
    has_line_mode = not is_nil(edit_value(edit, :start_line))

    cond do
      has_string_mode and has_line_mode ->
        {:error, "edit specifies both old_str and start_line. Pick one mode per edit."}

      has_string_mode ->
        apply_string_edit(body, edit)

      has_line_mode ->
        apply_line_range_edit(body, edit)

      true ->
        {:error,
         "edit must contain either old_str (string mode) or start_line + end_line + new_content (line-range mode)."}
    end
  end

  defp apply_single_edit(_body, _), do: {:error, "edit must be a map"}

  defp apply_string_edit(body, edit) do
    old_str = edit_value(edit, :old_str)
    new_str = edit_value(edit, :new_str) || ""
    replace_all = edit_value(edit, :replace_all) == true

    cond do
      not is_binary(old_str) or old_str == "" ->
        {:error, "old_str must be a non-empty string"}

      not is_binary(new_str) ->
        {:error, "new_str must be a string"}

      true ->
        occurrences = count_occurrences(body, old_str)

        cond do
          occurrences == 0 ->
            {:error, "old_str not found in current buffer"}

          occurrences > 1 and not replace_all ->
            {:error,
             "old_str appears #{occurrences} times; set replace_all: true or add surrounding context to make it unique"}

          true ->
            new_body =
              if replace_all do
                String.replace(body, old_str, new_str)
              else
                String.replace(body, old_str, new_str, global: false)
              end

            {:ok, new_body,
             %{
               mode: "string",
               replacements: if(replace_all, do: occurrences, else: 1)
             }}
        end
    end
  end

  defp apply_line_range_edit(body, edit) do
    start_line = edit_value(edit, :start_line)
    end_line = edit_value(edit, :end_line)
    new_content = edit_value(edit, :new_content) || ""

    lines = String.split(body, "\n")
    total = length(lines)

    cond do
      not is_integer(start_line) ->
        {:error, "start_line must be an integer"}

      not is_integer(end_line) ->
        {:error, "end_line must be an integer"}

      not is_binary(new_content) ->
        {:error, "new_content must be a string"}

      start_line < 1 ->
        {:error, "start_line must be >= 1, got #{start_line}"}

      end_line < start_line - 1 ->
        {:error, "end_line (#{end_line}) must be >= start_line - 1 (#{start_line - 1})"}

      start_line > total + 1 ->
        {:error, "start_line #{start_line} exceeds current buffer length (#{total} lines)"}

      end_line > total ->
        {:error, "end_line #{end_line} exceeds current buffer length (#{total} lines)"}

      true ->
        before = Enum.take(lines, start_line - 1)

        after_lines =
          if end_line < start_line do
            Enum.drop(lines, start_line - 1)
          else
            Enum.drop(lines, end_line)
          end

        merged =
          cond do
            new_content == "" and end_line >= start_line ->
              before ++ after_lines

            true ->
              before ++ String.split(new_content, "\n") ++ after_lines
          end

        {:ok, Enum.join(merged, "\n"),
         %{mode: "line_range", lines_replaced: "#{start_line}-#{end_line}"}}
    end
  end

  # Edits come from JSON tool args (string keys) or from Elixir tests
  # (atom keys). Accept either.
  defp edit_value(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  # ---------------------------------------------------------------------------
  # undo_last_edit
  # ---------------------------------------------------------------------------

  defp do_undo_last_edit(page_id, ctx) do
    with {:ok, page} <- Brain.get_page(page_id, actor: ctx.user),
         {:ok, versions} <- list_update_body_versions(page_id) do
      # Snapshot mode stores POST-change body in each version. The
      # current body == the most recent version's body. To undo, restore
      # to whatever the second-most-recent version stored. If only one
      # update_body version exists, the prior body is whatever existed
      # before that single save (which we approximate as "").
      sorted = Enum.sort_by(versions, & &1.version_inserted_at, {:desc, NaiveDateTime})

      case sorted do
        [] ->
          {:ok,
           %{
             error: "No prior body version exists for this page. Nothing to undo.",
             page_id: page.id,
             current: build_current(load_brain(page, ctx), page)
           }}

        [_only_one] ->
          # Restore to "" — the state before the first update_body save.
          case save_body_with_retry(page, "", :undo, ctx) do
            {:ok, updated} ->
              brain = load_brain(updated, ctx)

              {:ok,
               %{
                 action: "undo_last_edit",
                 page_id: updated.id,
                 page_title: updated.title,
                 current: build_current(brain, updated),
                 hint: "Restored to empty (no prior version existed)."
               }}

            {:error, err} ->
              {:ok, %{error: tool_error("undo last edit", err, nil)}}
          end

        [_latest, prior | _] ->
          prior_body = prior.changes["body"] || prior.changes[:body] || ""

          case save_body_with_retry(page, prior_body, :undo, ctx) do
            {:ok, updated} ->
              brain = load_brain(updated, ctx)

              {:ok,
               %{
                 action: "undo_last_edit",
                 page_id: updated.id,
                 page_title: updated.title,
                 current: build_current(brain, updated),
                 hint: "Restored to prior version."
               }}

            {:error, %VersionConflict{} = conflict} ->
              {:ok, conflict_payload("undo last edit", conflict, page.id, ctx)}

            {:error, err} ->
              {:ok, %{error: tool_error("undo last edit", err, nil)}}
          end
      end
    else
      {:error, err} ->
        {:ok,
         %{
           error: tool_error("undo last edit", err, "Verify page_id with read_brain.")
         }}
    end
  end

  defp list_update_body_versions(page_id) do
    Magus.Brain.Page.Version
    |> Ash.Query.filter(version_source_id == ^page_id)
    |> Ash.Query.filter(version_action_name == :update_body)
    |> Ash.read(authorize?: false)
  end

  # ---------------------------------------------------------------------------
  # save_body_with_retry — the single write path with retry protocol
  # ---------------------------------------------------------------------------

  # `kind` is one of: :write_create | :write_replace | :write_append |
  # :write_prepend | :edit_string | :edit_line_range | :clear | :undo.
  # Line-range edits and undo do NOT auto-retry; everything else gets one
  # retry on VersionConflict by re-applying its operation against the
  # latest body. The string/replace/append/prepend modes need different
  # re-apply logic (you can't blindly write the same body twice — the
  # caller's intent was "apply this transform to whatever's there").
  defp save_body_with_retry(page, next_body, kind, ctx) do
    case Brain.update_page_body(
           page,
           %{body: next_body, base_version: page.lock_version},
           actor: ctx.user
         ) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, %Ash.Error.Invalid{errors: errors}} = err ->
        case Enum.find(errors, &match?(%VersionConflict{}, &1)) do
          %VersionConflict{} = conflict ->
            handle_lock_conflict(page, next_body, kind, ctx, conflict)

          nil ->
            err
        end

      other ->
        other
    end
  end

  # write_create can't conflict (we just created the page in the same
  # transaction). If it somehow does, surface it.
  defp handle_lock_conflict(_page, _next_body, :write_create, _ctx, conflict),
    do: {:error, conflict}

  # write_replace: just retry with the new lock_version. The intent is
  # "this body replaces whatever's there".
  defp handle_lock_conflict(page, next_body, :write_replace, ctx, conflict) do
    refreshed = refreshed_page(page, conflict)
    emit_lock_conflict_telemetry(:write_replace, :retried)
    retry_save(refreshed, next_body, ctx, :write_replace)
  end

  # write_append: re-combine fresh body + addition. Addition was the
  # whole `next_body` passed in, since the page was passed in pristine
  # (no prior body). Actually we lose context here — by the time we
  # reach `save_body_with_retry`, `next_body` is already the combined
  # result. We don't know the addition. So for append/prepend on
  # conflict we must re-derive: assume the original page body was the
  # prefix of next_body (or suffix for prepend), extract the addition,
  # and re-combine with the conflict's current_body.
  #
  # SAFER: callers should pass the addition separately. But to keep the
  # write path uniform, store the original page body when we hit this
  # case and use that to extract the addition.
  defp handle_lock_conflict(page, next_body, :write_append, ctx, conflict) do
    prior_body = page.body || ""
    addition = extract_append_addition(prior_body, next_body)
    refreshed = refreshed_page(page, conflict)
    new_combined = combine_append(refreshed.body || "", addition)
    emit_lock_conflict_telemetry(:write_append, :retried)
    retry_save(refreshed, new_combined, ctx, :write_append)
  end

  defp handle_lock_conflict(page, next_body, :write_prepend, ctx, conflict) do
    prior_body = page.body || ""
    addition = extract_prepend_addition(prior_body, next_body)
    refreshed = refreshed_page(page, conflict)
    new_combined = combine_prepend(refreshed.body || "", addition)
    emit_lock_conflict_telemetry(:write_prepend, :retried)
    retry_save(refreshed, new_combined, ctx, :write_prepend)
  end

  # edit_string retries are handled in do_edit_string_attempt where the
  # caller has the old_str/new_str to re-run. By the time we reach this
  # path next_body is the post-replace body, which would be the wrong
  # thing to write against the refreshed lock_version.
  defp handle_lock_conflict(_page, _next_body, :edit_string, _ctx, conflict),
    do: {:error, conflict}

  # Per plan: line-range edits don't auto-retry — line numbers may have
  # shifted, the agent should re-think.
  defp handle_lock_conflict(_page, _next_body, :edit_line_range, _ctx, conflict) do
    emit_lock_conflict_telemetry(:edit_line_range, :surrendered)
    {:error, conflict}
  end

  defp handle_lock_conflict(page, _next_body, :clear, ctx, conflict) do
    refreshed = refreshed_page(page, conflict)
    emit_lock_conflict_telemetry(:clear, :retried)
    retry_save(refreshed, "", ctx, :clear)
  end

  # undo: don't retry — the version we wanted to restore may not be the
  # most-recent anymore.
  defp handle_lock_conflict(_page, _next_body, :undo, _ctx, conflict),
    do: {:error, conflict}

  defp retry_save(page, body, ctx, kind) do
    case Brain.update_page_body(
           page,
           %{body: body, base_version: page.lock_version},
           actor: ctx.user
         ) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, %Ash.Error.Invalid{errors: errors}} = err ->
        case Enum.find(errors, &match?(%VersionConflict{}, &1)) do
          %VersionConflict{} = c ->
            emit_lock_conflict_telemetry(kind, :surrendered)
            {:error, c}

          _ ->
            err
        end

      other ->
        other
    end
  end

  defp extract_append_addition(prior, combined) do
    # combine_append uses "\n\n" as the join. Strip the prior body's
    # trailing whitespace and look for it as a prefix.
    prefix = String.trim_trailing(prior || "")

    cond do
      prefix == "" ->
        combined

      String.starts_with?(combined, prefix) ->
        rest = String.replace_prefix(combined, prefix, "")
        String.trim_leading(rest)

      true ->
        combined
    end
  end

  defp extract_prepend_addition(prior, combined) do
    suffix = String.trim_leading(prior || "")

    cond do
      suffix == "" ->
        combined

      String.ends_with?(combined, suffix) ->
        len = byte_size(combined) - byte_size(suffix)
        prefix_part = binary_part(combined, 0, len)
        String.trim_trailing(prefix_part)

      true ->
        combined
    end
  end

  # Merge the conflict's current_body and current_version back onto the
  # original page struct so retry_save has a Page-shaped record to write
  # against. We don't need a full Brain.get_page round-trip — the
  # MatchesLockVersion change does a `SELECT ... FOR UPDATE` re-read on
  # the actual write — so this is just enough to thread id/title/etc.
  # forward into the retry.
  defp refreshed_page(%Magus.Brain.Page{} = page, %VersionConflict{} = conflict) do
    %{page | body: conflict.current_body, lock_version: conflict.current_version}
  end

  # ---------------------------------------------------------------------------
  # Conflict payload (shared shape)
  # ---------------------------------------------------------------------------

  defp conflict_payload(operation, %VersionConflict{} = conflict, page_id, ctx) do
    %{
      error:
        "Concurrent edit detected during #{operation}. The page changed under you; re-read and retry.",
      conflict: true,
      page_id: page_id,
      current_body: conflict.current_body,
      current_version: conflict.current_version,
      current_modified_at: conflict.current_modified_at,
      conflicting_actor_id: conflict.conflicting_actor_id,
      current: build_current(load_brain_by_page_id(page_id, ctx), nil)
    }
  end

  # ---------------------------------------------------------------------------
  # read_page helpers
  # ---------------------------------------------------------------------------

  defp resolve_page_for_read(context, params, brain_id, ctx) do
    cond do
      page_id = get_param(params, :page_id) ->
        Brain.get_page(page_id, actor: ctx.user)

      page_title = get_param(params, :page_title) ->
        cond do
          slash_path?(page_title) ->
            segments = parse_slash(page_title)

            case resolve_leaf_via_chain(brain_id, segments, ctx) do
              {:ok, page} -> {:ok, page}
              :not_found -> {:error, "Page not found: #{page_title}"}
            end

          true ->
            case find_existing_page(brain_id, page_title, ctx) do
              {:ok, page} -> {:ok, page}
              :not_found -> {:error, "Page not found: '#{page_title}'"}
            end
        end

      pane_page_id = Map.get(context, :brain_page_id) || Map.get(context, "brain_page_id") ->
        Brain.get_page(pane_page_id, actor: ctx.user)

      true ->
        {:error,
         "No page specified. Provide page_id, page_title, or open a page in the brain pane."}
    end
  end

  defp count_occurrences(text, substring)
       when is_binary(text) and is_binary(substring) and substring != "" do
    length(String.split(text, substring)) - 1
  end

  defp count_occurrences(_, _), do: 0

  # ---------------------------------------------------------------------------
  # Diff
  # ---------------------------------------------------------------------------

  defp build_unified_diff(old_body, new_body, title) do
    old_lines = String.split(old_body || "", "\n")
    new_lines = String.split(new_body || "", "\n")

    diff = List.myers_difference(old_lines, new_lines)

    body =
      diff
      |> Enum.flat_map(&format_diff_chunk/1)
      |> Enum.join("\n")

    "--- #{title}\n+++ #{title}\n" <> body
  end

  defp format_diff_chunk({:eq, lines}) when length(lines) > 6 do
    first = lines |> Enum.take(2) |> Enum.map(&" #{&1}")
    last = lines |> Enum.take(-2) |> Enum.map(&" #{&1}")
    omitted = length(lines) - 4
    first ++ ["... (#{omitted} unchanged lines)"] ++ last
  end

  defp format_diff_chunk({:eq, lines}), do: Enum.map(lines, &" #{&1}")
  defp format_diff_chunk({:del, lines}), do: Enum.map(lines, &"-#{&1}")
  defp format_diff_chunk({:ins, lines}), do: Enum.map(lines, &"+#{&1}")

  # ---------------------------------------------------------------------------
  # `current` echo + brain loading
  # ---------------------------------------------------------------------------

  defp build_current(nil, nil), do: %{}

  defp build_current(brain, nil) when is_map(brain) do
    %{brain_id: brain.id, brain_title: brain.title}
  end

  defp build_current(nil, page) when is_map(page) do
    %{page_id: page.id, page_title: page.title}
  end

  defp build_current(brain, page) when is_map(brain) and is_map(page) do
    %{
      brain_id: brain.id,
      brain_title: brain.title,
      page_id: page.id,
      page_title: page.title
    }
  end

  defp load_brain(nil, _ctx), do: nil

  defp load_brain(%{brain_id: brain_id}, ctx) do
    load_brain_by_id(brain_id, ctx)
  end

  defp load_brain(_, _), do: nil

  defp load_brain_by_id(nil, _ctx), do: nil

  defp load_brain_by_id(brain_id, ctx) do
    case Brain.get_brain(brain_id, actor: ctx.user) do
      {:ok, brain} -> brain
      _ -> nil
    end
  end

  defp load_brain_by_page_id(page_id, ctx) do
    case Brain.get_page(page_id, actor: ctx.user) do
      {:ok, page} -> load_brain(page, ctx)
      _ -> nil
    end
  end

  defp build_breadcrumb(page, ctx) do
    case Brain.list_pages(page.brain_id, actor: ctx.user) do
      {:ok, all_pages} -> Magus.Brain.Hierarchy.build_breadcrumb(page, all_pages)
      _ -> page.title
    end
  end

  # ---------------------------------------------------------------------------
  # Misc helpers
  # ---------------------------------------------------------------------------

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  defp count_descendants(page_id, ctx) do
    case Brain.list_children_pages(page_id, actor: ctx.user) do
      {:ok, children} ->
        length(children) +
          Enum.sum(Enum.map(children, fn c -> count_descendants(c.id, ctx) end))

      _ ->
        0
    end
  end

  defp maybe_open_brain_pane(context, brain_id, page_id) do
    case context[:conversation_id] || context["conversation_id"] do
      nil -> :ok
      conversation_id -> Signals.open_brain_pane(conversation_id, brain_id, page_id)
    end
  end

  defp removed_actions, do: ~w(add_block edit_block delete_block move_block link)

  # ---------------------------------------------------------------------------
  # Telemetry (Phase C10)
  # ---------------------------------------------------------------------------

  defp emit_lock_conflict_telemetry(mode, outcome) do
    :telemetry.execute(
      [:brain, :lock_conflict],
      %{count: 1},
      %{mode: mode, outcome: outcome}
    )
  end

  defp emit_collision_telemetry(brain_id, page_id, page_title, supplied_mode) do
    :telemetry.execute(
      [:brain, :write_page, :collision],
      %{count: 1},
      %{
        brain_id: brain_id,
        page_id: page_id,
        page_title: page_title,
        agent_supplied_mode: supplied_mode
      }
    )
  end

  defp emit_edit_miss_telemetry(brain_id, page_id, old_str) do
    preview = old_str |> to_string() |> String.slice(0, 80)

    :telemetry.execute(
      [:brain, :edit_page, :miss],
      %{count: 1},
      %{
        brain_id: brain_id,
        page_id: page_id,
        old_str_preview: preview,
        fuzzy_suggestion_used: false
      }
    )
  end

  defp emit_edit_ambiguous_telemetry(brain_id, page_id, match_count, replace_all_used) do
    :telemetry.execute(
      [:brain, :edit_page, :ambiguous],
      %{count: 1, match_count: match_count},
      %{
        brain_id: brain_id,
        page_id: page_id,
        replace_all_used: replace_all_used
      }
    )
  end
end
