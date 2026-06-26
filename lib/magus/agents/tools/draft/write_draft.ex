defmodule Magus.Agents.Tools.Draft.WriteDraft do
  @moduledoc """
  Jido tool for creating or updating draft documents in the side pane.

  Supports two modes:
  - **Full mode** (no old_text): Creates or fully replaces the draft content
  - **Surgical mode** (with old_text): Finds and replaces the matching text

  Supports multiple drafts per conversation:
  - Defaults to editing the active draft (the one open in the user's pane)
  - Use `draft_id` to target a specific draft
  - Use `create_new: true` to create a new draft even if one exists
  """

  use Jido.Action,
    name: "write_draft",
    description: """
    Create or update a draft document in the side pane. Use for long-form content like proposals, reports, or documentation.
    - Full replace: Provide title + content (no old_text) to create or rewrite the entire document.
    - Surgical edit: Provide old_text + content to find and replace that exact text.
      If the same text appears more than once, also provide hint_line (1-indexed) to pick the occurrence nearest that line.
      Use read_draft first to see the current content.
    - To edit a specific draft, provide its draft_id.
    - To create a new separate document, set create_new to true.
    """,
    schema: [
      title: [
        type: :string,
        required: true,
        doc: "Document title"
      ],
      content: [
        type: :string,
        required: true,
        doc: "Full document content OR replacement text for the matched old_text"
      ],
      old_text: [
        type: {:or, [:string, nil]},
        required: false,
        default: nil,
        doc: "The exact text to find and replace. If provided, enables surgical edit mode."
      ],
      hint_line: [
        type: {:or, [:integer, nil]},
        required: false,
        default: nil,
        doc: "Approximate line number to disambiguate when old_text appears multiple times."
      ],
      draft_id: [
        type: {:or, [:string, nil]},
        required: false,
        default: nil,
        doc: "Target a specific draft by ID. If not provided, edits the active draft."
      ],
      create_new: [
        type: :boolean,
        required: false,
        default: false,
        doc: "Set to true to create a new draft even if drafts already exist."
      ]
    ]

  require Logger

  alias Magus.Agents.Signals
  alias Magus.Agents.Tools.Helpers
  alias Magus.Agents.Tools.Draft.DraftHelpers
  alias Magus.Drafts.ProseMirrorConverter

  import Helpers, only: [validate_context: 2, get_param: 2, ai_actor: 0, count_lines: 1]

  def display_name, do: "Writing draft..."

  def summarize_output(%{mode: "created", title: title}), do: "Created: #{title}"
  def summarize_output(%{mode: "updated", title: title}), do: "Updated: #{title}"
  def summarize_output(%{mode: "edited_text"}), do: "Edited text"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Draft updated"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id, :user_id]) do
      {:ok, ctx} ->
        title = get_param(params, :title)
        content = get_param(params, :content) || ""
        old_text = get_param(params, :old_text)
        hint_line = get_param(params, :hint_line)
        draft_id = get_param(params, :draft_id)
        create_new = get_param(params, :create_new) || false

        content = Helpers.maybe_unescape_content(content)

        if old_text do
          old_text = Helpers.maybe_unescape_content(old_text)
          surgical_edit(ctx, title, content, old_text, hint_line, draft_id, context)
        else
          full_write(ctx, title, content, draft_id, create_new, context)
        end

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp full_write(ctx, title, content, _draft_id, true, context) do
    # create_new: true — always create a new draft
    Signals.emit_tool_progress(context, :writing_draft, %{title: title, mode: "new"})
    create_draft(ctx, title, content)
  end

  defp full_write(ctx, title, content, draft_id, _create_new, context) do
    Signals.emit_tool_progress(context, :writing_draft, %{title: title})

    case DraftHelpers.resolve_draft(ctx, draft_id, context) do
      {:ok, nil} ->
        create_draft(ctx, title, content)

      {:ok, draft} ->
        update_draft(draft, title, content)

      {:error, error} ->
        {:ok, %{error: Helpers.extract_error_message(error)}}
    end
  end

  defp create_draft(ctx, title, content) do
    case Magus.Drafts.create_draft(ctx.conversation_id, title, content, ctx.user_id,
           actor: ai_actor()
         ) do
      {:ok, draft} ->
        {:ok,
         %{
           draft_id: draft.id,
           title: draft.title,
           version: draft.version,
           line_count: draft.content |> ProseMirrorConverter.to_markdown() |> count_lines(),
           mode: "created"
         }}

      {:error, error} ->
        {:ok, %{error: Helpers.extract_error_message(error)}}
    end
  end

  defp update_draft(draft, title, content) do
    case Magus.Drafts.update_draft_content(draft, content, actor: ai_actor()) do
      {:ok, updated} ->
        updated = maybe_update_title(updated, title, draft.title)

        {:ok,
         %{
           draft_id: updated.id,
           title: updated.title,
           version: updated.version,
           line_count: updated.content |> ProseMirrorConverter.to_markdown() |> count_lines(),
           mode: "updated"
         }}

      {:error, error} ->
        {:ok, %{error: Helpers.extract_error_message(error)}}
    end
  end

  defp surgical_edit(ctx, title, new_text, old_text, hint_line, draft_id, context) do
    Signals.emit_tool_progress(context, :writing_draft, %{mode: "surgical"})

    case DraftHelpers.resolve_draft(ctx, draft_id, context) do
      {:ok, nil} ->
        {:ok,
         %{
           error: "No draft exists for this conversation. Create one first without old_text."
         }}

      {:ok, draft} ->
        case Magus.Drafts.replace_draft_text(draft, old_text, new_text, hint_line,
               actor: ai_actor()
             ) do
          {:ok, updated} ->
            updated = maybe_update_title(updated, title, draft.title)

            {:ok,
             %{
               draft_id: updated.id,
               title: updated.title,
               version: updated.version,
               line_count: updated.content |> ProseMirrorConverter.to_markdown() |> count_lines(),
               mode: "edited_text"
             }}

          {:error, error} ->
            {:ok, %{error: Helpers.extract_error_message(error)}}
        end

      {:error, error} ->
        {:ok, %{error: Helpers.extract_error_message(error)}}
    end
  end

  defp maybe_update_title(draft, title, original_title) do
    if title != original_title do
      case Magus.Drafts.update_draft_title(draft, title, actor: ai_actor()) do
        {:ok, retitled} -> retitled
        {:error, _} -> draft
      end
    else
      draft
    end
  end
end
