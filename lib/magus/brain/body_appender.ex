defmodule Magus.Brain.BodyAppender do
  @moduledoc """
  Helpers that append markdown snippets to a `Magus.Brain.Page`'s body
  via `Magus.Brain.update_page_body/3`.

  Phase C5 of the markdown-storage migration: chat-message "Add to brain"
  buttons, the brain pane's file picker / drag-drop / link funnels, and
  any other UI affordance that used to create a typed `Magus.Brain.Block`
  now append a markdown snippet to the page body instead.

  Markdown shapes mirror `Magus.Brain.BlockSerializer.to_markdown/1` so
  pages backfilled in Phase B and pages mutated in C5 produce the same
  output:

    * `:message`  → `[[msg:<id>|<preview>]]` (preview pipe-stripped to 500 chars)
    * `:source`   → fenced ` ```source ` block with url/title/source_type
    * `:file`     → `[📎 caption](magus://file/<id>)`
    * `:image`    → `![caption](magus://image/<id>)`

  Concurrency: `update_page_body` returns a `Magus.Brain.Page.Errors.VersionConflict`
  on stale `lock_version`. `append/3` retries once by re-fetching the
  current body from the conflict and re-appending the same snippet, since
  the user's intent is "stick this onto the end" regardless of what else
  changed in between. Two consecutive conflicts surface to the caller.
  """

  alias Magus.Brain
  alias Magus.Brain.Page
  alias Magus.Brain.Page.Errors.VersionConflict

  @typedoc """
  Result of an append. `{:ok, page}` is the updated page; the error tuples
  cover the two cases callers care about for UX (no-op vs. user-visible
  failure):

    * `{:error, :empty}` — the rendered markdown was empty (e.g. file id
      blank), no save attempted.
    * `{:error, reason}` — any other error (Ash invalid, version conflict
      surviving the retry, etc.).
  """
  @type append_result :: {:ok, Page.t()} | {:error, term()}

  @doc """
  Append a chat-message reference (`[[msg:<id>|<preview>]]`) to the page
  body. `preview` is sliced to 500 chars and stripped of pipe / bracket
  characters that would break the wikilink syntax.
  """
  @spec append_message(
          Page.t(),
          %{
            required(:message_id) => String.t(),
            optional(:preview) => String.t() | nil
          },
          Ash.Resource.record() | map()
        ) :: append_result()
  def append_message(page, %{message_id: message_id} = attrs, actor) do
    preview = Map.get(attrs, :preview)
    snippet = render_message(message_id, preview)
    do_append(page, snippet, actor)
  end

  @doc """
  Append a source reference (fenced ` ```source ` block) to the page
  body. `:url` is required. Optional keys: `:title`, `:source_type`
  (defaults to `"web"`), `:description`, `:author`.
  """
  @spec append_source(Page.t(), map(), Ash.Resource.record() | map()) :: append_result()
  def append_source(page, %{url: url} = attrs, actor) when is_binary(url) and url != "" do
    snippet = render_source(attrs)
    do_append(page, snippet, actor)
  end

  def append_source(_page, _attrs, _actor), do: {:error, :empty}

  @doc """
  Append a file or image link to the page body. The link form depends on
  the file's `:type` attribute (`:image` becomes the inline image syntax
  `![caption](magus://image/<id>)`, everything else becomes
  `[📎 caption](magus://file/<id>)`).

  `caption` defaults to an empty string.
  """
  @spec append_file(
          Page.t(),
          Magus.Files.File.t() | map(),
          String.t() | nil,
          Ash.Resource.record() | map()
        ) :: append_result()
  def append_file(page, %{id: file_id, type: type}, caption, actor)
      when is_binary(file_id) and file_id != "" do
    snippet = render_file(file_id, type, caption || "")
    do_append(page, snippet, actor)
  end

  def append_file(_page, _file, _caption, _actor), do: {:error, :empty}

  @doc """
  Convenience wrapper around `append_file/4` that loads the file by id
  using the given actor. The canonical funnel for the slash picker,
  drag-drop, and sidebar-link paths — all three only have a file id at
  the call site.

  Returns the same shape as `append_file/4`, plus `{:error, :file_not_found}`
  when the file can't be loaded (id missing, access denied, soft-deleted).
  """
  @spec append_file_by_id(Page.t(), String.t(), String.t() | nil, Ash.Resource.record() | map()) ::
          append_result()
  def append_file_by_id(page, file_id, caption, actor)
      when is_binary(file_id) and file_id != "" do
    case Magus.Files.get_file(file_id, actor: actor) do
      {:ok, file} -> append_file(page, file, caption, actor)
      _ -> {:error, :file_not_found}
    end
  end

  def append_file_by_id(_page, _file_id, _caption, _actor),
    do: {:error, :file_not_found}

  # ----------------------------------------------------------------------
  # Rendering — mirrors BlockSerializer.to_markdown/1
  # ----------------------------------------------------------------------

  defp render_message(message_id, preview) when is_binary(message_id) and message_id != "" do
    # Mirror BlockSerializer.sanitize_msg_preview/1: wikilinks cannot span
    # newlines (the JS regex `[[([^\]\n]+)]]` would skip them), so collapse
    # whitespace and strip the syntax-breaking chars.
    clean_preview =
      (preview || "")
      |> String.slice(0, 500)
      |> String.replace(["|", "[", "]"], " ")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    case clean_preview do
      "" -> "[[msg:#{message_id}]]"
      text -> "[[msg:#{message_id}|#{text}]]"
    end
  end

  defp render_message(_, _), do: ""

  defp render_source(%{url: url} = attrs) do
    title = Map.get(attrs, :title)
    source_type = Map.get(attrs, :source_type) || "web"
    description = Map.get(attrs, :description)
    author = Map.get(attrs, :author)

    pairs =
      [
        {"url", url},
        {"title", title || url},
        {"source_type", source_type},
        {"description", description},
        {"author", author}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{escape_yaml_scalar(to_string(v))}" end)

    "```source\n#{pairs}\n```"
  end

  defp render_file(file_id, :image, caption),
    do: "![#{caption}](magus://image/#{file_id})"

  defp render_file(file_id, _other_type, caption),
    do: "[📎 #{caption}](magus://file/#{file_id})"

  # Same escape rules as BlockSerializer.escape_yaml_scalar/1.
  defp escape_yaml_scalar(s) when is_binary(s) do
    cond do
      String.contains?(s, ["\n", "\r"]) ->
        ~s("#{s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"") |> String.replace("\n", "\\n")}")

      String.contains?(s, [":", "#", "[", "]", "{", "}", ",", "\"", "\\"]) or
        String.starts_with?(s, " ") or String.ends_with?(s, " ") ->
        escaped = s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
        ~s("#{escaped}")

      true ->
        s
    end
  end

  defp escape_yaml_scalar(s), do: to_string(s)

  # ----------------------------------------------------------------------
  # Save path with single retry on VersionConflict
  # ----------------------------------------------------------------------

  defp do_append(_page, "", _actor), do: {:error, :empty}

  defp do_append(page, snippet, actor) do
    save(page, append_to_body(page.body, snippet), actor, snippet)
  end

  defp save(page, new_body, actor, snippet) do
    case Brain.update_page_body(
           page,
           %{body: new_body, base_version: page.lock_version},
           actor: actor
         ) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, %Ash.Error.Invalid{errors: errors}} = err ->
        case Enum.find(errors, &match?(%VersionConflict{}, &1)) do
          %VersionConflict{
            current_body: current_body,
            current_version: current_version
          } ->
            retry(page, current_body, current_version, snippet, actor)

          nil ->
            err
        end

      other ->
        other
    end
  end

  defp retry(page, current_body, current_version, snippet, actor) do
    refreshed = %{page | body: current_body, lock_version: current_version}

    Brain.update_page_body(
      refreshed,
      %{body: append_to_body(current_body, snippet), base_version: current_version},
      actor: actor
    )
  end

  defp append_to_body(nil, snippet), do: snippet
  defp append_to_body("", snippet), do: snippet

  defp append_to_body(body, snippet) when is_binary(body) do
    trimmed = String.trim_trailing(body)
    "#{trimmed}\n\n#{snippet}"
  end
end
