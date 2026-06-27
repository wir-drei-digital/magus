defmodule Magus.Skills do
  @moduledoc """
  Skills domain: user-managed, workspace-shareable skills. A skill is the
  Anthropic Agent Skills `SKILL.md` format extended as a superset: a markdown
  body plus optional bundled scripts that run in the sandbox (bundles land in
  a later plan). This plan establishes the resource, sharing, and RPC surface.
  """

  use Ash.Domain, otp_app: :magus

  @doc "Whether the user-managed skills feature is enabled for this instance."
  def enabled? do
    Application.get_env(:magus, __MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  resources do
    resource Magus.Skills.Skill do
      define :create_skill, action: :create
      define :get_skill, action: :read, get_by: [:id]
      define :update_skill, action: :update
      define :destroy_skill, action: :destroy
      define :list_skills, action: :read
    end
  end
end
