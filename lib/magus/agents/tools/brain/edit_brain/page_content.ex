defmodule Magus.Agents.Tools.Brain.EditBrain.PageContent do
  @moduledoc """
  `EditBrain` action handlers for page BODY content: `write_page`,
  `edit_page` (string + line-range modes), `multi_edit`, `clear_page`,
  and `undo_last_edit`.

  Extracted verbatim from `Magus.Agents.Tools.Brain.EditBrain` as part
  of the Task B11 dispatch-handler split; behavior is unchanged. Each
  `handle_*/4` function is called directly from the tool's `dispatch/4`
  and returns the same `{:ok, map()}` shape the inline clause used to.
  """

  require Ash.Query

  alias Magus.Brain
  alias Magus.Brain.Page.Errors.VersionConflict
  alias Magus.Agents.Tools.Brain.EditBrain.Support
  alias Magus.Agents.Tools.Brain.BrainResolver
  alias Magus.Agents.Signals

  import Magus.Agents.Tools.Helpers,
    only: [get_param: 2, get_optional_int_param: 2, flag_param?: 2, tool_error: 3]

  import Support,
    only: [
      build_current: 2,
      load_brain: 2,
      build_breadcrumb: 2,
      blank?: 1,
      conflict_payload: 4,
      resolve_page_for_read: 4,
      count_occurrences: 2,
      save_body_with_retry: 4,
      combine_append: 2,
      combine_prepend: 2,
      build_unified_diff: 3,
      slash_path?: 1,
      parse_slash: 1,
      resolve_leaf_via_chain: 3,
      find_existing_page: 3,
      emit_lock_conflict_telemetry: 2
    ]

  @write_modes ~w(create replace append prepend)

  # ---------------------------------------------------------------------------
  # write_page
  # ---------------------------------------------------------------------------

  def handle_write_page(params, ctx, context) do
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
        {:ok,
         %{
           error:
             "Missing required parameter: title (or page_id). To write the page open in " <>
               "the pane/companion, pass its page_id explicitly (it is shown in your context)."
         }}

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

  def handle_edit_page(params, ctx, context) do
    with {:ok, brain_id} <- BrainResolver.resolve_brain_id(context, params),
         {:ok, page} <- resolve_page_for_read(context, params, brain_id, ctx) do
      old_str = get_param(params, :old_str)
      new_str = get_param(params, :new_str)
      # Coerced: LLMs send line numbers as strings ("3"), which used to reach
      # the arithmetic below and crash with a bare ArithmeticError.
      start_line = get_optional_int_param(params, :start_line)
      end_line = get_optional_int_param(params, :end_line)
      new_content = get_param(params, :new_content)

      cond do
        not is_nil(old_str) ->
          replace_all = flag_param?(params, :replace_all)
          hint_line = get_optional_int_param(params, :hint_line)
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

  # Page resolution mirrors edit_page: explicit page_id, page_title lookup,
  # or the open pane page — so the model can target the page the same way
  # across every body-editing action.
  def handle_multi_edit(params, ctx, context) do
    edits = coerce_edits(get_param(params, :edits))

    if not is_list(edits) or edits == [] do
      {:ok, %{error: "Missing or empty required parameter: edits (non-empty list)"}}
    else
      with {:ok, brain_id} <- BrainResolver.resolve_brain_id(context, params),
           {:ok, page} <- resolve_page_for_read(context, params, brain_id, ctx) do
        do_multi_edit(page, edits, ctx)
      else
        {:error, msg} when is_binary(msg) -> {:ok, %{error: msg}}
        {:error, err} -> {:ok, %{error: tool_error("multi_edit", err, nil)}}
      end
    end
  end

  # LLMs sometimes send the edits array as a JSON-encoded string instead of a
  # real list. Decode that so multi_edit isn't rejected (otherwise the model
  # retries and falls back to slower one-at-a-time edits). A non-decodable
  # string is left as-is so the "non-empty list" error below stays accurate.
  defp coerce_edits(edits) when is_list(edits), do: edits

  defp coerce_edits(edits) when is_binary(edits) do
    case Jason.decode(edits) do
      {:ok, decoded} when is_list(decoded) -> decoded
      _ -> edits
    end
  end

  defp coerce_edits(other), do: other

  # ---------------------------------------------------------------------------
  # clear_page
  # ---------------------------------------------------------------------------

  def handle_clear_page(params, ctx, context) do
    with {:ok, brain_id} <- BrainResolver.resolve_brain_id(context, params),
         {:ok, page} <- resolve_page_for_read(context, params, brain_id, ctx),
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
        {:ok, conflict_payload("clear page", conflict, get_param(params, :page_id), ctx)}

      {:error, msg} when is_binary(msg) ->
        {:ok, %{error: msg}}

      {:error, err} ->
        {:ok,
         %{
           error: tool_error("clear page", err, "Verify page_id with read_brain list_pages.")
         }}
    end
  end

  # ---------------------------------------------------------------------------
  # undo_last_edit
  # ---------------------------------------------------------------------------

  def handle_undo_last_edit(params, ctx, context) do
    with {:ok, brain_id} <- BrainResolver.resolve_brain_id(context, params),
         {:ok, page} <- resolve_page_for_read(context, params, brain_id, ctx) do
      do_undo_last_edit(page.id, ctx)
    else
      {:error, msg} when is_binary(msg) -> {:ok, %{error: msg}}
      {:error, err} -> {:ok, %{error: tool_error("undo last edit", err, nil)}}
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

          payload = %{
            action: "write_page",
            page_id: updated.id,
            page_title: updated.title,
            mode: mode_label,
            current: build_current(brain, updated)
          }

          # Just-in-time steering for pure-tool flows: a write is a filing
          # decision, so the location's Guide rides on the result even when
          # no companion/pane injected it up front. Nil (no guide) adds
          # nothing.
          {:ok, put_guide(payload, brain, updated, ctx)}

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

  # Attaches the location's Guide block to a tool payload (no-op when the
  # brain has no guide). See BrainContext.tool_guide_section/3.
  defp put_guide(payload, brain, page, ctx) do
    case Magus.Agents.Context.BrainContext.tool_guide_section(brain, page, ctx.user) do
      nil -> payload
      guide -> Map.put(payload, :guide, guide)
    end
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
    case mode |> String.trim() |> String.downcase() do
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
          # Refuse rather than restore to "": with a single version, "undo"
          # would silently blank a just-written page — an agent reverting
          # "my last change" destroys the content instead. The model can
          # still clear deliberately via clear_page.
          {:ok,
           %{
             error:
               "Only one saved version exists; there is no earlier content to restore. " <>
                 "Use edit_page/write_page to change the content, or clear_page to empty it deliberately.",
             page_id: page.id,
             current: build_current(load_brain(page, ctx), page)
           }}

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
  # Telemetry (Phase C10)
  # ---------------------------------------------------------------------------

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

  defp maybe_open_brain_pane(context, brain_id, page_id) do
    case context[:conversation_id] || context["conversation_id"] do
      nil -> :ok
      conversation_id -> Signals.open_brain_pane(conversation_id, brain_id, page_id)
    end
  end
end
