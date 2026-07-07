defmodule Magus.Agents.Tools.Brain.EditBrain.Support do
  @moduledoc """
  Shared internals for the `EditBrain` tool's action handler submodules
  (`PageContent`, `Structure`).

  This holds the pieces that are genuinely cross-cutting rather than
  owned by a single action: the `current` echo + brain/breadcrumb
  loading, the page-lookup-for-editing resolution (including
  slash-path walking), the optimistic-lock retry protocol for body
  writes (`save_body_with_retry/4` and friends), append/prepend body
  combination, and the unified diff renderer.

  Extracted verbatim from `Magus.Agents.Tools.Brain.EditBrain` as part
  of the Task B11 dispatch-handler split; behavior is unchanged.
  """

  alias Magus.Brain
  alias Magus.Brain.Page.Errors.VersionConflict

  import Magus.Agents.Tools.Helpers, only: [get_param: 2]

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
  def save_body_with_retry(page, next_body, kind, ctx) do
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

  def extract_append_addition(prior, combined) do
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

  def extract_prepend_addition(prior, combined) do
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
  def refreshed_page(%Magus.Brain.Page{} = page, %VersionConflict{} = conflict) do
    %{page | body: conflict.current_body, lock_version: conflict.current_version}
  end

  def combine_append(nil, addition), do: addition
  def combine_append("", addition), do: addition
  def combine_append(existing, ""), do: existing

  def combine_append(existing, addition) do
    String.trim_trailing(existing) <> "\n\n" <> String.trim_leading(addition)
  end

  def combine_prepend(nil, addition), do: addition
  def combine_prepend("", addition), do: addition
  def combine_prepend(existing, ""), do: existing

  def combine_prepend(existing, addition) do
    String.trim_trailing(addition) <> "\n\n" <> String.trim_leading(existing)
  end

  # ---------------------------------------------------------------------------
  # Conflict payload (shared shape)
  # ---------------------------------------------------------------------------

  def conflict_payload(operation, %VersionConflict{} = conflict, page_id, ctx) do
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
  # read_page helpers (page lookup for editing)
  # ---------------------------------------------------------------------------

  def resolve_page_for_read(context, params, brain_id, ctx) do
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

  def count_occurrences(text, substring)
      when is_binary(text) and is_binary(substring) and substring != "" do
    length(String.split(text, substring)) - 1
  end

  def count_occurrences(_, _), do: 0

  # ---------------------------------------------------------------------------
  # Diff
  # ---------------------------------------------------------------------------

  def build_unified_diff(old_body, new_body, title) do
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

  def build_current(nil, nil), do: %{}

  def build_current(brain, nil) when is_map(brain) do
    %{brain_id: brain.id, brain_title: brain.title}
  end

  def build_current(nil, page) when is_map(page) do
    %{page_id: page.id, page_title: page.title}
  end

  def build_current(brain, page) when is_map(brain) and is_map(page) do
    %{
      brain_id: brain.id,
      brain_title: brain.title,
      page_id: page.id,
      page_title: page.title
    }
  end

  def load_brain(nil, _ctx), do: nil

  def load_brain(%{brain_id: brain_id}, ctx) do
    load_brain_by_id(brain_id, ctx)
  end

  def load_brain(_, _), do: nil

  def load_brain_by_id(nil, _ctx), do: nil

  def load_brain_by_id(brain_id, ctx) do
    case Brain.get_brain(brain_id, actor: ctx.user) do
      {:ok, brain} -> brain
      _ -> nil
    end
  end

  def load_brain_by_page_id(page_id, ctx) do
    case Brain.get_page(page_id, actor: ctx.user) do
      {:ok, page} -> load_brain(page, ctx)
      _ -> nil
    end
  end

  def build_breadcrumb(page, ctx) do
    case Brain.list_pages(page.brain_id, actor: ctx.user) do
      {:ok, all_pages} -> Magus.Brain.Hierarchy.build_breadcrumb(page, all_pages)
      _ -> page.title
    end
  end

  # ---------------------------------------------------------------------------
  # Slash-path resolution
  # ---------------------------------------------------------------------------

  def parse_slash(path) do
    path
    |> String.split("/")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def slash_path?(title) when is_binary(title) do
    title |> parse_slash() |> length() |> Kernel.>(1)
  end

  def slash_path?(_), do: false

  def resolve_leaf_via_chain(brain_id, segments, ctx) do
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

  def find_existing_page(brain_id, title, ctx) do
    case Brain.find_page_by_title(brain_id, title, actor: ctx.user) do
      {:ok, [page | _]} -> {:ok, page}
      {:ok, []} -> :not_found
      _ -> :not_found
    end
  end

  # ---------------------------------------------------------------------------
  # Misc helpers
  # ---------------------------------------------------------------------------

  def blank?(nil), do: true
  def blank?(""), do: true
  def blank?(s) when is_binary(s), do: String.trim(s) == ""
  def blank?(_), do: false

  # ---------------------------------------------------------------------------
  # Telemetry (Phase C10)
  # ---------------------------------------------------------------------------

  def emit_lock_conflict_telemetry(mode, outcome) do
    :telemetry.execute(
      [:brain, :lock_conflict],
      %{count: 1},
      %{mode: mode, outcome: outcome}
    )
  end
end
