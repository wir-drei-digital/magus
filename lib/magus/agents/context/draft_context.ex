defmodule Magus.Agents.Context.DraftContext do
  @moduledoc """
  Builds lightweight draft context for AI agents.

  Provides a summary of all drafts in the conversation, marking the active one.
  Injected into the system prompt. Does NOT include full content to preserve
  context window budget — the agent uses `read_draft` tool when it needs the actual text.

  Follows the same pattern as `WorkspaceContext`.
  """

  @spec build(Ecto.UUID.t(), Ecto.UUID.t() | nil, keyword()) :: String.t() | nil
  def build(conversation_id, active_draft_id \\ nil, opts \\ [])

  def build(conversation_id, active_draft_id, opts) when is_binary(conversation_id) do
    case Magus.Drafts.list_drafts_for_conversation(conversation_id, opts) do
      {:ok, []} ->
        nil

      {:ok, [single_draft]} ->
        build_single_context(single_draft)

      {:ok, drafts} ->
        build_multi_context(drafts, active_draft_id)

      {:error, _} ->
        nil
    end
  end

  def build(_, _, _), do: nil

  defp build_single_context(draft) do
    line_count = draft_line_count(draft)

    """
    ## Active Draft

    There is an active draft document in the side pane:

    **Title:** #{draft.title}
    **Version:** #{draft.version} (#{line_count} lines)

    Use `read_draft` to view the full content with line numbers. Use `write_draft` to replace the entire document or surgically edit specific lines.
    The user can select text in the draft and send messages about it — check for [Draft selection] context in user messages.
    To create a separate document, use `write_draft` with `create_new: true`.
    """
    |> String.trim()
  end

  defp build_multi_context(drafts, active_draft_id) do
    items =
      drafts
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {draft, idx} ->
        line_count = draft_line_count(draft)
        active = if draft.id == active_draft_id, do: " [ACTIVE]", else: " — id: #{draft.id}"
        "#{idx}. **#{draft.title}** (v#{draft.version}, #{line_count} lines)#{active}"
      end)

    """
    ## Drafts

    There are #{length(drafts)} draft documents in this conversation:

    #{items}

    Use `read_draft` to view a draft's content. Use `write_draft` to edit the active draft or specify `draft_id` to target another.
    When the user asks you to write or edit, update the active draft unless they explicitly request a new document (use `create_new: true`).
    The user can select text in the draft and send messages about it — check for [Draft selection] context in user messages.
    """
    |> String.trim()
  end

  defp draft_line_count(draft) do
    draft.content
    |> Magus.Drafts.ProseMirrorConverter.to_markdown()
    |> Magus.Agents.Tools.Helpers.count_lines()
  end
end
