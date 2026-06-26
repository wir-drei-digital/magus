defmodule Magus.Accounts.ApiToken.Changes.GenerateSecret do
  @moduledoc false
  use Ash.Resource.Change

  alias Magus.Accounts.ApiToken.Secret

  @impl true
  def change(changeset, _opts, _context) do
    plaintext = Secret.generate()

    changeset
    |> Ash.Changeset.force_change_attribute(:key_hash, Secret.hash(plaintext))
    |> Ash.Changeset.force_change_attribute(:key_prefix, Secret.prefix(plaintext))
    |> Ash.Changeset.after_action(fn _cs, record ->
      {:ok, Ash.Resource.put_metadata(record, :plaintext, plaintext)}
    end)
  end
end
