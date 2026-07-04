defmodule Magus.Memory.UserProfile.Changes.CreateVersion do
  @moduledoc "Snapshots the profile document after every set_document."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, profile ->
      changed_by =
        if match?(%Magus.Agents.Support.AiAgent{}, context.actor), do: :distiller, else: :system

      {:ok, _version} =
        Magus.Memory.create_profile_version(
          %{
            user_profile_id: profile.id,
            document: profile.document,
            token_estimate: profile.token_estimate,
            changed_by: changed_by
          },
          authorize?: false
        )

      {:ok, profile}
    end)
  end
end
