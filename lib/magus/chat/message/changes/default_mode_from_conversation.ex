defmodule Magus.Chat.Message.Changes.DefaultModeFromConversation do
  @moduledoc """
  Defaults the message's `mode` to the conversation's `chat_mode` when the
  client did not send one.

  The `mode` attribute is NOT NULL with a static `:chat` default, so by the
  time `Dispatcher.build_signal_data/3` runs, `message.mode` is never nil and
  its `|| conversation.chat_mode` fallback can never fire. Clients that don't
  echo the conversation mode on every send (the SPA composer) would silently
  route image/video-mode turns through the chat model. This change makes the
  conversation's mode the effective default at creation time, so the persisted
  `mode` reflects the mode the turn actually runs in.

  Must be declared after `CreateConversationIfNotProvided` so the
  `conversation_id` attribute is set (both changes do their work in
  `before_action` hooks, which run in declaration order).
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    # `params` holds the raw client input; `get_attribute` would already
    # return the static :chat default and can't detect omission.
    if Map.has_key?(changeset.params, :mode) or Map.has_key?(changeset.params, "mode") do
      changeset
    else
      Ash.Changeset.before_action(changeset, &set_mode_from_conversation/1)
    end
  end

  defp set_mode_from_conversation(changeset) do
    with conversation_id when not is_nil(conversation_id) <-
           Ash.Changeset.get_attribute(changeset, :conversation_id),
         {:ok, %{chat_mode: chat_mode}} when not is_nil(chat_mode) <-
           Magus.Chat.get_conversation(conversation_id, authorize?: false) do
      Ash.Changeset.force_change_attribute(changeset, :mode, chat_mode)
    else
      _ -> changeset
    end
  end
end
