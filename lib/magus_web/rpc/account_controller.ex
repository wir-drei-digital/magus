defmodule MagusWeb.Rpc.AccountController do
  @moduledoc """
  Account-level data actions for the SvelteKit settings "Data" section
  (`/rpc/account/*`): a deletion preflight summary and the destructive account
  delete. Runs in the session-authenticated `:rpc` pipeline; the heavy delete
  logic (Stripe cancel, owned-content cleanup, sole-admin guard) lives in
  `Magus.Accounts.AccountDeletion`. Data export stays a plain browser download
  (`GET /settings/data/export`). Responses mirror the AshTypescript RPC
  envelope (`{success, data | errors}`).
  """
  use MagusWeb, :controller

  import AshAuthentication.Phoenix.Controller, only: [clear_session: 2]

  def deletion_preflight(conn, _params) do
    user = conn.assigns.current_user

    case Magus.Accounts.AccountDeletion.preflight(user) do
      {:ok, summary} ->
        json(conn, %{success: true, data: %{canDelete: true, summary: serialize_summary(summary)}})

      {:error, :sole_admin_workspaces, workspaces} ->
        json(conn, %{
          success: true,
          data: %{canDelete: false, soleAdminWorkspaces: Enum.map(workspaces, & &1.name)}
        })
    end
  end

  def delete(conn, %{"confirmEmail" => typed}) when is_binary(typed) do
    user = conn.assigns.current_user

    if String.downcase(typed) != String.downcase(to_string(user.email)) do
      json(conn, error_envelope("Email did not match. Account was not deleted."))
    else
      case Magus.Accounts.AccountDeletion.execute(user) do
        :ok ->
          conn
          |> clear_session(:magus)
          |> json(%{success: true, data: %{deleted: true}})

        {:error, :lifecycle_aborted} ->
          json(
            conn,
            error_envelope(
              "We could not cancel your subscription. Please try again or contact support."
            )
          )

        {:error, :sole_admin_workspaces, _workspaces} ->
          json(
            conn,
            error_envelope(
              "You are still the only admin of one or more workspaces. Transfer admin rights or delete those workspaces first."
            )
          )

        {:error, _other} ->
          json(conn, error_envelope("Could not delete account. Please contact support."))
      end
    end
  end

  def delete(conn, _params), do: json(conn, error_envelope("Email confirmation required."))

  defp serialize_summary(summary) do
    %{
      activeSubscription:
        case summary.active_subscription do
          nil -> nil
          %{plan: plan, current_period_end: ends} -> %{plan: plan, currentPeriodEnd: ends}
        end,
      multiplayerMembershipCount: summary.multiplayer_membership_count,
      conversationCount: summary.conversation_count,
      brainCount: summary.brain_count,
      memoryCount: summary.memory_count,
      promptCount: summary.prompt_count,
      draftCount: summary.draft_count,
      customAgentCount: summary.custom_agent_count
    }
  end

  defp error_envelope(message) do
    %{
      success: false,
      errors: [
        %{
          type: "account_error",
          message: message,
          shortMessage: "Account action failed",
          vars: %{},
          fields: [],
          path: []
        }
      ]
    }
  end
end
