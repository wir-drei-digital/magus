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
  end

  resources do
    resource Magus.Organizations.Organization do
      define :create_organization, action: :create
      define :get_organization, action: :read, get_by: [:id]
      define :get_organization_by_slug, action: :read, get_by: [:slug]
      define :update_organization, action: :update
    end
  end
end
