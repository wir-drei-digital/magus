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

  require Ash.Query

  @doc """
  Returns `%{key => value}` for the intersection of `keys` and the user's stored
  sandbox secrets. Only declared keys are ever returned; unknown keys are absent.
  """
  def sandbox_env_for_user(user_id, keys) when is_list(keys) do
    wanted = MapSet.new(keys)

    Magus.Skills.SandboxSecret
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&MapSet.member?(wanted, &1.key))
    |> Map.new(fn s -> {s.key, s.value} end)
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

    resource Magus.Skills.SkillTrust do
      rpc_action :my_skill_trusts, :my_trusts
      rpc_action :trust_skill, :create
      rpc_action :untrust_skill, :destroy
    end

    # `value` is not public, so the my_sandbox_secrets list action never exposes it.
    resource Magus.Skills.SandboxSecret do
      rpc_action :my_sandbox_secrets, :my_secrets
      rpc_action :create_sandbox_secret, :create
      rpc_action :update_sandbox_secret, :update
      rpc_action :destroy_sandbox_secret, :destroy
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
      define :fulltext_search_skill, action: :fulltext_search, args: [:query]
      define :share_skill_to_team, action: :share_to_team
      define :unshare_skill_from_team, action: :unshare_from_team
    end

    resource Magus.Skills.SkillFavorite do
      define :favorite_skill, action: :create
      define :unfavorite_skill, action: :destroy
      define :my_skill_favorites, action: :my_favorites
    end

    resource Magus.Skills.ConversationSkillApproval do
      define :record_conversation_approval, action: :record
      define :list_conversation_approvals, action: :for_conversation, args: [:conversation_id]
    end

    resource Magus.Skills.SkillTrust do
      define :trust_skill, action: :create
      define :untrust_skill, action: :destroy
      define :my_skill_trusts, action: :my_trusts
    end

    resource Magus.Skills.SandboxSecret do
      define :create_sandbox_secret, action: :create
      define :update_sandbox_secret, action: :update
      define :destroy_sandbox_secret, action: :destroy
      define :my_sandbox_secrets, action: :my_secrets
    end
  end
end
