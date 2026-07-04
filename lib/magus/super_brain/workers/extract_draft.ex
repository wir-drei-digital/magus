defmodule Magus.SuperBrain.Workers.ExtractDraft do
  @moduledoc """
  Extracts entities and edges from drafts into the owning user's drafts graph.

  Drafts are collaborative scratchpads in the `Magus.Drafts` domain — both
  the user and the agent can write to them. The 60-second Oban uniqueness
  window combined with the content fingerprint gate (in `ExtractBase`)
  absorbs the noise from rapid keystroke-level edits without coalescing
  semantically distinct revisions.

  Routing:

      drafts:user:<draft.user_id>

  The parent `conversation_id` is written as an entity property so callers
  can roll up provenance back to the originating conversation without an
  extra join.

  Pipeline implemented by `Magus.SuperBrain.Workers.ExtractBase`. This module
  only implements the resource-specific `load/1` callback. The base handles
  fingerprint gating, budget killswitch, Episode lifecycle, MessageUsage
  writes, and graph writes.

  ## Text extraction

  Drafts store `content` as a ProseMirror JSON document (the TipTap
  document format), not raw text. We use
  `Magus.Drafts.ProseMirrorConverter.to_plain_text/1` to flatten the doc
  to extractable text. Empty docs become empty strings, which the base
  pipeline handles gracefully (no LLM call beyond an empty fingerprint).
  """

  use Magus.SuperBrain.Workers.ExtractBase, queue: :super_brain_extraction

  alias Magus.Drafts.ProseMirrorConverter

  @extractor_version "draft_extract_worker@2026-07-04-claims"

  @impl true
  def extractor_version, do: @extractor_version

  @impl true
  def load(%{"resource_id" => draft_id}) when is_binary(draft_id) do
    case Ash.get(Magus.Drafts.Draft, draft_id, authorize?: false) do
      {:ok, %{user_id: nil}} ->
        {:error, :draft_has_no_owner}

      {:ok, draft} ->
        raw_text = extract_text(draft.content) || ""

        {:ok,
         %{
           user_id: draft.user_id,
           raw_text: raw_text,
           graph_name: "drafts:user:#{draft.user_id}",
           resource_type: :draft,
           resource_id: draft.id,
           source_weight: 1.0,
           extra_node_props: %{conversation_id: draft.conversation_id}
         }}

      {:error, %Ash.Error.Query.NotFound{}} ->
        {:error, :draft_not_found}

      {:error, _} = err ->
        err
    end
  end

  def load(_), do: {:error, :missing_resource_id}

  # ---------------------------------------------------------------------------
  # ProseMirror -> plain text
  # ---------------------------------------------------------------------------

  # ProseMirror documents always look like %{"type" => "doc", "content" => [...]}.
  # We delegate to the canonical converter so the text projection matches what
  # users see in the rendered draft pane.
  defp extract_text(%{"type" => "doc"} = doc), do: ProseMirrorConverter.to_plain_text(doc)

  # Defensive fallbacks - shouldn't happen with the current schema (content is
  # NOT NULL with a default doc), but guard against future shape drift so the
  # worker degrades gracefully rather than crashing the Oban job.
  defp extract_text(text) when is_binary(text), do: text
  defp extract_text(%{} = map), do: map[:text] || map["text"] || inspect(map)
  defp extract_text(_), do: nil
end
