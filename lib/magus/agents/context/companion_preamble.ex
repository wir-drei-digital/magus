defmodule Magus.Agents.Context.CompanionPreamble do
  @moduledoc """
  Builds the system-prompt preamble for companion conversations (a
  conversation linked to a file or brain page via
  `Magus.Chat.ConversationCompanion`). Returns "" for non-companion
  conversations so it can be called unconditionally during context
  assembly.
  """

  alias Magus.Agents.Context.BrainContext

  # The full companion page body is inlined into the system prompt so the agent
  # never has to call `read_page` for its own page. Capped to keep token cost
  # bounded; a truncation note points at `read_page` for the rare huge page.
  @companion_body_limit 24_000

  @spec build(map()) :: String.t()
  def build(%{conversation_id: conv_id, user: %{} = user} = args) do
    workspace_id = Map.get(args, :workspace_id)

    case Magus.Chat.get_companion_by_conversation(conv_id, actor: user) do
      {:ok, %{resource_type: :file, resource_id: id}} ->
        build_file_section(id, user)

      {:ok, %{resource_type: :brain_page, resource_id: id}} ->
        build_brain_page_section(id, user, workspace_id)

      _ ->
        ""
    end
  end

  def build(_), do: ""

  defp build_file_section(file_id, user) do
    case Magus.Files.get_file(file_id, actor: user) do
      {:ok, file} -> file_template(file)
      _ -> ""
    end
  end

  defp build_brain_page_section(page_id, user, workspace_id) do
    case Magus.Brain.get_page(page_id, actor: user, load: [:brain]) do
      {:ok, page} ->
        pages =
          case Magus.Brain.list_pages(page.brain_id, actor: user) do
            {:ok, list} -> list
            _ -> []
          end

        brain_title = brain_title(page.brain) || "Untitled brain"
        title = page.title || "Untitled page"

        [
          brain_page_intro(page, title, brain_title),
          BrainContext.available_brains_section(user, workspace_id),
          "### Page tree — " <> brain_title <> "\n\n" <> BrainContext.full_tree(pages, page.id),
          "### Current page: " <> title <> "\n\n" <> companion_body(page.body),
          companion_file_summary(page, user)
        ]
        |> Enum.reject(&(is_nil(&1) or &1 == ""))
        |> Enum.join("\n\n")

      _ ->
        ""
    end
  end

  defp brain_page_intro(page, title, brain_title) do
    brain_id = brain_id(page.brain)

    """
    ## Active companion context

    You are the dedicated chat companion for the user's brain page **#{title}** (page_id: #{page.id}) in the brain **#{brain_title}** (brain_id: #{brain_id}). The user is viewing it right now.

    Treat this page as the implicit subject of the user's questions unless they say otherwise. **Its full current content and this brain's complete page tree are included below — you do NOT need to call `read_brain` to read this page or to list pages.** To change the page, call `edit_brain`. Use `read_brain(action: "read_page", page_id: "...")` only to open a DIFFERENT page, and `read_brain(action: "search", query: "...", brain_id: "#{brain_id}")` for semantic search across the brain.\
    """
  end

  defp brain_id(%{id: id}) when is_binary(id), do: id
  defp brain_id(_), do: "unknown"

  defp companion_body(body) when is_binary(body) do
    trimmed = String.trim(body)

    cond do
      trimmed == "" ->
        "_(empty page)_"

      String.length(trimmed) <= @companion_body_limit ->
        trimmed

      true ->
        String.slice(trimmed, 0, @companion_body_limit) <>
          "\n\n…(truncated; call read_brain read_page for the full body)"
    end
  end

  defp companion_body(_), do: "_(empty page)_"

  # The existing file-reference summary already returns a leading-newline
  # string; trim it so the section composer can join consistently.
  defp companion_file_summary(page, user) do
    page |> build_file_summary(user) |> String.trim()
  end

  defp build_file_summary(%{body: body}, user) when is_binary(body) do
    file_ids = Magus.Brain.BodyParser.file_ids(body)

    files =
      file_ids
      |> Enum.map(fn id ->
        case Magus.Files.get_file(id, actor: user) do
          {:ok, file} -> file
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    case files do
      [] ->
        ""

      list ->
        names = list |> Enum.take(5) |> Enum.map_join(", ", & &1.name)
        count = length(list)
        noun = if count == 1, do: "file", else: "files"

        """

        This page references #{count} #{noun}: #{names}. Use `read_brain(action: "search", ...)` to find passages within them, or `search_files` for direct content lookups.
        """
    end
  end

  defp build_file_summary(_page, _user), do: ""

  defp brain_title(%{title: t}) when is_binary(t) and t != "", do: t
  defp brain_title(_), do: nil

  defp file_template(file) do
    """
    ## Active companion context

    You are the dedicated chat companion for the user's #{kind(file)} **#{file.name}**
    (file_id: #{file.id}, mime: #{file.mime_type || "unknown"}, size: #{format_bytes(file.file_size)}).
    The user is viewing it in the adjacent pane right now.

    Treat this file as the implicit subject of the user's questions unless they say otherwise.

    To read the file's contents, call `search_files(query: "...")`. The companion conversation
    inherits this file's workspace, so search_files will surface chunks from this file
    (and any siblings in the same workspace).

    Do not invent content. If the user's question requires reading the file and you haven't
    yet, call the appropriate tool first.
    """
  end

  defp kind(%{type: :document, mime_type: "application/pdf"}), do: "PDF"
  defp kind(%{type: :document}), do: "document"
  defp kind(%{type: :image}), do: "image"
  defp kind(%{type: :video}), do: "video"
  defp kind(%{type: :text}), do: "text file"
  defp kind(%{type: :email}), do: "email"
  defp kind(_), do: "file"

  defp format_bytes(nil), do: "unknown size"
  defp format_bytes(b) when b < 1024, do: "#{b} B"
  defp format_bytes(b) when b < 1024 * 1024, do: "#{Float.round(b / 1024, 1)} KB"
  defp format_bytes(b), do: "#{Float.round(b / (1024 * 1024), 1)} MB"
end
