defmodule Magus.Integrations.IntegrationConversation.Checks.ActorOwnsUserIntegration do
  @moduledoc """
  Checks that the actor owns the user integration referenced by the action.
  """

  use Ash.Policy.SimpleCheck

  require Ash.Query

  @impl true
  def describe(_opts), do: "actor owns the target user integration"

  @impl true
  def match?(%{id: actor_id}, %{changeset: changeset}, _opts) do
    user_integration_id = Ash.Changeset.get_argument(changeset, :user_integration_id)

    case user_integration_id do
      nil ->
        false

      id ->
        Magus.Integrations.UserIntegration
        |> Ash.Query.filter(id == ^id and user_id == ^actor_id)
        |> Ash.read_one(authorize?: false)
        |> case do
          {:ok, nil} -> false
          {:ok, _integration} -> true
          {:error, _} -> false
        end
    end
  end

  def match?(_, _, _), do: false
end
