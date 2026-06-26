defmodule Magus.Chat.ConversationInviteLink.Changes.HashPassword do
  @moduledoc """
  Hashes the password for password-protected invite links.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :password) do
      nil ->
        changeset

      "" ->
        changeset

      password ->
        hash = Bcrypt.hash_pwd_salt(password)
        Ash.Changeset.force_change_attribute(changeset, :password_hash, hash)
    end
  end
end
