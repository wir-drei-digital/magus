defmodule Magus.Accounts.User.Changes.CreateFreeSubscription do
  @moduledoc """
  Creates a free tier subscription for newly registered users.

  This change is idempotent - it checks if the user already has a subscription
  before creating one. This handles both fresh registrations and magic link
  sign-ins where the user might already exist.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, user ->
      create_subscription_if_needed(user)
    end)
  end

  defp create_subscription_if_needed(user) do
    case Magus.Usage.get_user_subscription(user.id, authorize?: false) do
      {:ok, _subscription} ->
        # User already has a subscription, nothing to do
        {:ok, user}

      {:error, %Ash.Error.Query.NotFound{}} ->
        # No subscription found, create one
        create_free_subscription(user)

      {:error, _reason} ->
        # Treat other errors as "no subscription found" for safety
        create_free_subscription(user)
    end
  end

  defp create_free_subscription(user) do
    with {:ok, free_plan} <- Magus.Usage.get_free_plan(authorize?: false),
         {:ok, _subscription} <-
           Magus.Usage.create_user_subscription(
             %{
               user_id: user.id,
               usage_plan_id: free_plan.id,
               status: :active,
               storage_usage_bytes: 0
             },
             authorize?: false
           ) do
      {:ok, user}
    else
      {:error, %Ash.Error.Query.NotFound{}} ->
        # Free plan doesn't exist yet (e.g., in tests without seeds)
        # Log warning but don't fail user registration
        require Logger
        Logger.warning("Free plan not found - user #{user.id} registered without subscription")
        {:ok, user}

      {:error, reason} ->
        # Log error but don't fail user registration
        require Logger
        Logger.error("Failed to create subscription for user #{user.id}: #{inspect(reason)}")
        {:ok, user}
    end
  end
end
