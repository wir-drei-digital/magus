defmodule Magus.Models.Provider.Changes.EnqueueCredentialValidation do
  @moduledoc "Enqueues async credential validation. Body added in Task 9."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context), do: changeset
end
