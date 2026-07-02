defmodule Magus.Skills do
  @moduledoc """
  Skills domain: user-managed, workspace-shareable skills. A skill is the
  Anthropic Agent Skills `SKILL.md` format extended as a superset: a markdown
  body plus optional bundled scripts that run in the sandbox (bundles land in
  a later plan). This plan establishes the resource, sharing, and RPC surface.
  """

  use Ash.Domain, otp_app: :magus, extensions: [AshTypescript.Rpc]

  @doc """
  Whether the user-managed skills feature is enabled for this instance.

  When false, user skills are hidden from discovery and bundle import is refused
  (the runtime surface is disabled).
  """
  def enabled? do
    Application.get_env(:magus, __MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  typescript_rpc do
    resource Magus.Skills.Skill do
      rpc_action :my_skills, :my_skills
      rpc_action :workspace_skills, :workspace_skills
      rpc_action :my_favorite_skills, :my_favorite_skills
      rpc_action :create_skill, :create
      rpc_action :update_skill, :update
      rpc_action :destroy_skill, :destroy
      rpc_action :share_skill_to_team, :share_to_team
      rpc_action :unshare_skill_from_team, :unshare_from_team

      rpc_action :get_skill, :read do
        get_by [:id]
      end
    end

    resource Magus.Skills.SkillFavorite do
      rpc_action :my_skill_favorites, :my_favorites
      rpc_action :favorite_skill, :create
      rpc_action :unfavorite_skill, :destroy
    end
  end

  resources do
    resource Magus.Skills.Skill do
      define :create_skill, action: :create
      define :import_skill, action: :import
      define :get_skill, action: :read, get_by: [:id]
      define :update_skill, action: :update
      define :destroy_skill, action: :destroy
      define :list_skills, action: :read
      define :my_skills, action: :my_skills
      define :workspace_skills, action: :workspace_skills, args: [:workspace_id]
      define :my_favorite_skills, action: :my_favorite_skills
      define :share_skill_to_team, action: :share_to_team
      define :unshare_skill_from_team, action: :unshare_from_team
    end

    resource Magus.Skills.SkillFavorite do
      define :favorite_skill, action: :create
      define :unfavorite_skill, action: :destroy
      define :my_skill_favorites, action: :my_favorites
    end
  end
end
