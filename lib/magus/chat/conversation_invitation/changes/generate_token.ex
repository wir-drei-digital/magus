defmodule Magus.Chat.ConversationInvitation.Changes.GenerateToken do
  @moduledoc """
  Generates a unique token for email invitations.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    token = generate_token()
    Ash.Changeset.force_change_attribute(changeset, :token, token)
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end
end
