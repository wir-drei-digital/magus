defmodule Magus.Workspaces do
  @moduledoc """
  Workspaces domain: workspaces, their members, and the shared resource-access
  grant model (`ResourceAccess`) that scopes folders, files, conversations,
  prompts, agents, brains, and collections across users and workspaces.
  """

  use Ash.Domain,
    otp_app: :magus,
    extensions: [AshPhoenix, AshPaperTrail.Domain, AshTypescript.Rpc]

  paper_trail do
    include_versions? true
  end

  typescript_rpc do
    resource Magus.Workspaces.Workspace do
      rpc_action :my_workspaces, :my_workspaces
      rpc_action :create_workspace, :create
      rpc_action :update_workspace, :update
      rpc_action :deactivate_workspace, :deactivate

      rpc_action :get_workspace_by_slug, :read do
        get_by [:slug]
      end

      rpc_action :workspace_member_usage, :member_usage
    end

    resource Magus.Workspaces.WorkspaceMember do
      rpc_action :list_workspace_members, :by_workspace
      rpc_action :invite_workspace_member, :invite
      rpc_action :resend_workspace_invite, :resend_invite
      rpc_action :change_workspace_member_role, :change_role
      rpc_action :deactivate_workspace_member, :deactivate
      rpc_action :transfer_workspace_ownership, :transfer_ownership
    end
  end

  resources do
    resource Magus.Workspaces.Workspace do
      define :create_workspace, action: :create
      define :get_workspace, action: :read, get_by: [:id]
      define :get_workspace_by_slug, action: :read, get_by: [:slug]
      define :my_workspaces, action: :my_workspaces
      define :update_workspace, action: :update
      define :admin_update_workspace, action: :admin_update
      define :all_workspaces, action: :all_workspaces
      define :deactivate_workspace, action: :deactivate

      define :increment_workspace_storage,
        action: :increment_storage,
        args: [:bytes],
        get_by: [:id]

      define :decrement_workspace_storage,
        action: :decrement_storage,
        args: [:bytes],
        get_by: [:id]

      define :recalculate_workspace_storage, action: :recalculate_storage
    end

    resource Magus.Workspaces.WorkspaceMember do
      define :invite_member, action: :invite, args: [:workspace_id, :invite_email]
      define :resend_invite, action: :resend_invite
      define :change_member_role, action: :change_role, args: [:role]
      define :deactivate_member, action: :deactivate
      define :transfer_ownership_to, action: :transfer_ownership
      define :list_workspace_members, action: :by_workspace, args: [:workspace_id]
      define :get_member_by_token, action: :by_invite_token, args: [:invite_token]
    end

    resource Magus.Workspaces.ResourceAccess do
      define :grant_access, action: :grant
      define :revoke_access, action: :revoke
      define :update_access_role, action: :update_role

      define :list_access_for_resource,
        action: :for_resource,
        args: [:resource_type, :resource_id]

      define :list_access_for_grantee, action: :for_grantee, args: [:grantee_type, :grantee_id]
    end
  end

  def accept_invite(invite_token, opts \\ []) do
    case get_member_by_token(invite_token, authorize?: false) do
      {:ok, member} ->
        if invite_expired?(member) do
          {:error, :expired}
        else
          member
          |> Ash.Changeset.for_update(:accept, %{}, opts)
          |> Ash.update(opts)
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  defp invite_expired?(%{invite_expires_at: nil}), do: false

  defp invite_expired?(%{invite_expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  end
end
