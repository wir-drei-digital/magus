defmodule Magus.Models.Provider.Changes.DestroyOwnedModels do
  @moduledoc """
  Before destroying an owned provider, deletes its owned models (the models
  FK restricts otherwise). Runs in the same transaction; scoped to rows that
  are both owned and linked to this provider.
  """
  use Ash.Resource.Change
  import Ecto.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      provider = cs.data

      if is_binary(provider.owner_user_id) do
        from(m in "models",
          where:
            m.model_provider_id == type(^provider.id, :binary_id) and not is_nil(m.owner_user_id)
        )
        |> Magus.Repo.delete_all()

        cs
      else
        Ash.Changeset.add_error(cs, field: :base, message: "only user-owned providers")
      end
    end)
  end
end
