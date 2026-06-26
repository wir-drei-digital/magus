defmodule Magus.Agents.Tools.Draft.DraftHelpers do
  @moduledoc """
  Shared helpers for draft tools (ReadDraft, WriteDraft).
  """

  import Magus.Agents.Tools.Helpers, only: [ai_actor: 0]

  @doc """
  Resolves the target draft using a priority chain:
  1. Explicit `draft_id` parameter (if provided)
  2. `active_draft_id` from tool context (the draft open in the user's pane)
  3. Most recent draft for the conversation (fallback)

  Returns `{:ok, draft}`, `{:ok, nil}`, or `{:error, reason}`.
  """
  def resolve_draft(_ctx, draft_id, _context) when is_binary(draft_id) and draft_id != "" do
    Magus.Drafts.get_draft(draft_id, actor: ai_actor())
  rescue
    e in [Ash.Error.Query.NotFound, Ash.Error.Invalid] ->
      _ = e
      {:ok, nil}
  end

  def resolve_draft(ctx, _draft_id, context) do
    active_id = Map.get(context, :active_draft_id)

    if is_binary(active_id) and active_id != "" do
      case Magus.Drafts.get_draft(active_id, actor: ai_actor()) do
        {:ok, draft} -> {:ok, draft}
        _ -> Magus.Drafts.get_draft_for_conversation(ctx.conversation_id, actor: ai_actor())
      end
    else
      Magus.Drafts.get_draft_for_conversation(ctx.conversation_id, actor: ai_actor())
    end
  end
end
