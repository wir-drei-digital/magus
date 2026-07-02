defmodule Magus.Organizations.Organization.Changes.CreateSharedWorkspace do
  @moduledoc """
  After creating an org, create one shared workspace owned by the org. The
  workspace's own :create bootstraps the creator as its admin member.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, org ->
      case Magus.Workspaces.create_workspace(
             %{name: "#{org.name} Team", slug: shared_workspace_slug(org)},
             actor: context.actor
           ) do
        {:ok, workspace} ->
          workspace
          |> Ash.Changeset.for_update(:set_organization, %{organization_id: org.id},
            authorize?: false
          )
          |> Ash.update!(actor: context.actor)

          {:ok, org}

        {:error, changeset} ->
          {:error, changeset}
      end
    end)
  end

  # Derive a machine-safe workspace slug that is valid for ANY allowed org slug.
  #
  # Org slugs are 2..64 chars matching ~r/\A[a-z0-9][a-z0-9-]*[a-z0-9]\z/, so a
  # naive "<org-slug>-team" overflows the 64-char workspace slug cap and collides
  # if the derived slug is already taken. Instead: keep a human-readable prefix of
  # the org slug, then append the tail of the org's (globally-unique) UUID so no
  # two orgs can derive the same workspace slug.
  #
  # Length is bounded: min(64, len) + "-team-" (6) + 12 hex = at most 46 + 6 + 12 = 64.
  # Regex validity: the first char comes from the org slug (always [a-z0-9]) and the
  # last char is a lowercase hex digit (always [a-z0-9]); everything between is
  # [a-z0-9-]. So the result always matches the workspace slug constraints.
  defp shared_workspace_slug(org) do
    prefix = String.slice(org.slug, 0, 46)
    id_tail = org.id |> String.replace("-", "") |> String.slice(-12, 12)
    "#{prefix}-team-#{id_tail}"
  end
end
