defmodule Magus.AiAgentActorPersister do
  use AshOban.ActorPersister

  def store(%Magus.Accounts.User{id: id}), do: %{"type" => "user", "id" => id}
  def store(%Magus.Agents.Support.AiAgent{}), do: %{"type" => "ai_agent"}

  def lookup(%{"type" => "user", "id" => id}) do
    with {:ok, user} <- Ash.get(Magus.Accounts.User, id, authorize?: false) do
      # you can change the behavior of actions
      # or what your policies allow
      # using the `chat_agent?` metadata
      {:ok, Ash.Resource.set_metadata(user, %{chat_agent?: true})}
    end
  end

  def lookup(%{"type" => "ai_agent"}) do
    {:ok, %Magus.Agents.Support.AiAgent{}}
  end

  # This allows you to set a default actor
  # in cases where no actor was present
  # when scheduling.
  def lookup(nil), do: {:ok, nil}
end
