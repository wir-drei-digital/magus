defmodule Magus.Chat.Message.Changes.StampDeliveredAt do
  @moduledoc """
  Re-stamps `inserted_at` to the current (delivery) time.

  A queued steering message is created the moment the user types it mid-turn,
  so its `inserted_at` is the *enqueue* time -- earlier than the agent reply
  that was still streaming at that point (the reply's row is only persisted at
  turn completion). Every transcript view orders by `inserted_at`, so without
  this the flushed follow-up would sort *above* that reply, leaving the user's
  messages stacked over an older agent message.

  Stamping the delivery time on flush makes the message order by when it was
  actually received into the conversation, fixing the order on every surface
  (live broadcast, `messages_since` reconcile, and history reload all carry
  `inserted_at`). `inserted_at` is a create timestamp (`writable? false`), so it
  is set via `force_change_attribute`.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.force_change_attribute(changeset, :inserted_at, DateTime.utc_now())
  end
end
