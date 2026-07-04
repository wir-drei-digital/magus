defmodule Magus.Agents.Tools.Memory.UpdateProfile do
  @moduledoc """
  Queues a durable behavioral note for the user's distilled profile.

  The note is folded into the profile document at the next distillation
  pass; the tool never edits the document directly, which keeps the
  document a single-writer artifact of DistillUserProfile.

  Registered unconditionally: with the user's `profile_enabled` setting off,
  notes queue harmlessly onto `pending_notes` and are simply never distilled
  (nothing reads them until DistillUserProfile runs).
  """

  use Jido.Action,
    name: "update_profile",
    description:
      "Queue a durable note about the user (preference, behavioral pattern, goal) " <>
        "for their distilled profile. Use only for signal that should persist across " <>
        "all conversations, not conversation-local facts.",
    schema: [
      note: [
        type: :string,
        required: true,
        doc: "One-sentence durable observation about the user"
      ]
    ]

  require Logger

  alias Magus.Memory

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2, get_param: 2, ai_actor: 0]

  def display_name, do: "Update Profile"

  def summarize_output(%{status: status}), do: "Profile note #{status}"
  def summarize_output(_), do: "Profile note queued"

  @impl true
  def run(params, context) do
    with {:ok, ctx} <- validate_context(context, [:user_id, :conversation_id]) do
      user_id = to_string(ctx.user_id)
      note = get_param(params, :note)
      workspace_id = Memory.workspace_id_for_conversation(ctx.conversation_id)

      with {:ok, profile} <- get_or_create(user_id, workspace_id),
           {:ok, updated} <- Memory.add_profile_note(profile, note, actor: ai_actor()) do
        {:ok, %{status: "queued", pending_notes: length(updated.pending_notes)}}
      else
        {:error, reason} ->
          Logger.warning("UpdateProfile: failed to queue note - #{inspect(reason)}")
          {:error, "Failed to queue profile note: #{inspect(reason)}"}
      end
    end
  end

  # `get_user_profile` (`:for_bucket`, `get? true`) defaults to
  # `not_found_error?: true`, so a bucket with no row yet returns an error
  # rather than `{:ok, nil}`. Treat any non-success as "no profile yet" and
  # create the (empty-document) row, mirroring DistillUserProfile.
  #
  # `unique_bucket` (`user_id`, `workspace_id`) makes this racy: if another
  # caller (e.g. a concurrent tool call, or DistillUserProfile) wins the
  # create for the same brand-new bucket, ours comes back as an
  # `{:error, %Ash.Error.Invalid{}}` unique-index violation. Re-read once
  # rather than aborting, so we queue the note onto the row that now exists
  # instead of silently dropping it.
  defp get_or_create(user_id, workspace_id) do
    case Memory.get_user_profile(user_id, workspace_id, actor: ai_actor()) do
      {:ok, profile} when not is_nil(profile) ->
        {:ok, profile}

      _ ->
        case Memory.create_user_profile(user_id, workspace_id, %{document: ""}, actor: ai_actor()) do
          {:ok, profile} ->
            {:ok, profile}

          {:error, _} ->
            Memory.get_user_profile(user_id, workspace_id, actor: ai_actor())
        end
    end
  end
end
