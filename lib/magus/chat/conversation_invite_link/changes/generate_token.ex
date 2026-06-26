defmodule Magus.Chat.ConversationInviteLink.Changes.GenerateToken do
  @moduledoc """
  Generates a secure random token for invite links.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    Ash.Changeset.force_change_attribute(changeset, :token, token)
  end
end
