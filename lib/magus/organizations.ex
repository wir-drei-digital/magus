defmodule Magus.Organizations do
  @moduledoc """
  Organizations domain: a billing group that owns one Stripe customer +
  subscription (written by the cloud edition) and consolidates the per-seat
  base fee and pay-as-you-go usage of its members. Entity, membership, roles,
  and workspace ownership live here in open core; all Stripe stays in cloud.
  """

  use Ash.Domain,
    otp_app: :magus,
    extensions: [AshPhoenix, AshPaperTrail.Domain, AshTypescript.Rpc]

  paper_trail do
    include_versions? true
  end

  # Registers the Organization resource with the AshTypescript RPC codegen.
  # Required because `Organization` carries the `AshTypescript.Resource`
  # extension; without this block `mix compile --warnings-as-errors` fails
  # (mirrors the `Magus.Workspaces` domain convention). rpc_action names are
  # global across the generated SPA client, hence the `organization`-prefixed
  # names.
  typescript_rpc do
    resource Magus.Organizations.Organization do
      rpc_action :create_organization, :create
      rpc_action :update_organization, :update

      rpc_action :get_organization, :read do
        get_by [:id]
      end

      rpc_action :get_organization_by_slug, :read do
        get_by [:slug]
      end
    end

    resource Magus.Organizations.OrganizationMember do
      rpc_action :invite_org_member, :invite
      rpc_action :list_org_members, :by_organization
      rpc_action :get_org_member_by_token, :by_invite_token
    end
  end

  resources do
    resource Magus.Organizations.Organization do
      define :create_organization, action: :create
      define :get_organization, action: :read, get_by: [:id]
      define :get_organization_by_slug, action: :read, get_by: [:slug]
      define :update_organization, action: :update
    end

    resource Magus.Organizations.OrganizationMember do
      define :invite_org_member, action: :invite, args: [:organization_id, :invite_email]
      define :list_org_members, action: :by_organization, args: [:organization_id]
      define :get_org_member_by_token, action: :by_invite_token, args: [:invite_token]
      define :change_org_member_role, action: :change_role, args: [:role]
      define :remove_org_member, action: :remove
      define :transfer_org_ownership, action: :transfer_ownership
      define :resend_org_invite, action: :resend_invite
    end
  end

  def accept_invite(invite_token, opts \\ []) do
    case get_org_member_by_token(invite_token, authorize?: false) do
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
