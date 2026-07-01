defmodule Magus.Accounts.User.Changes.CreateDemoSubscription do
  @moduledoc """
  Creates a Pay-as-you-go (PAYG) subscription for demo/test accounts.

  Unlike `CreateFreeSubscription`, this puts the account on the `payg` plan,
  which grants full entitlements — all models, the auto router (max routing
  tier `:complex`), and media generation — with NO Stripe connection (the PAYG
  plan's Stripe price ids are nil and no customer/subscription is created).
  Spend limits are additionally waived by the exemption override created
  alongside the account (see `Magus.Accounts.TestAccounts`).

  Idempotent: if the user somehow already has a subscription, it's left as-is.
  Falls back gracefully (logs, no subscription) if the PAYG plan is absent.
  """
  use Ash.Resource.Change
  require Logger

  @plan_key "payg"

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, user ->
      assign_payg_subscription(user)
    end)
  end

  defp assign_payg_subscription(user) do
    case Magus.Usage.get_user_subscription(user.id, authorize?: false) do
      {:ok, _subscription} ->
        {:ok, user}

      _ ->
        create_payg_subscription(user)
    end
  end

  defp create_payg_subscription(user) do
    with {:ok, plan} when not is_nil(plan) <-
           Magus.Usage.get_plan_by_key(@plan_key, authorize?: false),
         {:ok, _subscription} <-
           Magus.Usage.create_user_subscription(
             %{
               user_id: user.id,
               usage_plan_id: plan.id,
               status: :active,
               storage_usage_bytes: 0
             },
             authorize?: false
           ) do
      {:ok, user}
    else
      {:ok, nil} ->
        Logger.warning("PAYG plan not found - demo user #{user.id} created without subscription")
        {:ok, user}

      {:error, %Ash.Error.Query.NotFound{}} ->
        Logger.warning("PAYG plan not found - demo user #{user.id} created without subscription")
        {:ok, user}

      {:error, reason} ->
        Logger.error("Failed to create demo subscription for #{user.id}: #{inspect(reason)}")
        {:ok, user}
    end
  end
end
