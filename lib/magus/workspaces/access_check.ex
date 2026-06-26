defmodule Magus.Workspaces.AccessCheck do
  @moduledoc """
  Policy filter check plus imperative helper for generic resource_accesses grants.

  Used as a policy check inside the `Magus.Workspaces.Policies` macro's
  read/update/destroy blocks. Returns an Ash filter that, applied to the target
  resource's query, leaves only records the actor has access to at the required
  minimum role.

  Roles are ordered :viewer < :editor < :owner.
  """

  use Ash.Policy.FilterCheck

  @roles [viewer: 1, editor: 2, owner: 3]

  @impl true
  def describe(opts) do
    min_role = Keyword.fetch!(opts, :min_role)
    resource_type = Keyword.fetch!(opts, :resource_type)
    "actor has :#{min_role} access or higher to this #{resource_type}"
  end

  @impl true
  def filter(actor, _authorizer, opts) do
    resource_type = Keyword.fetch!(opts, :resource_type)
    min_role = Keyword.fetch!(opts, :min_role)
    allowed_roles = roles_satisfying(min_role)

    actor_id = actor_user_id(actor)
    agent_id = actor_agent_id(actor)
    workspace_ids = active_workspace_ids(actor_id)

    build_filter(resource_type, allowed_roles, actor_id, agent_id, workspace_ids)
  end

  # No identity to match against: deny everything. Returning a trivially-false
  # expression avoids nil-comparison warnings when Ash optimizes the filter.
  defp build_filter(_resource_type, _allowed_roles, nil, nil, _workspace_ids), do: expr(false)

  defp build_filter(resource_type, allowed_roles, actor_id, nil, []) do
    expr(
      exists(
        Magus.Workspaces.ResourceAccess,
        resource_type == ^resource_type and
          resource_id == parent(id) and
          role in ^allowed_roles and
          grantee_type == :user and grantee_id == ^actor_id
      )
    )
  end

  defp build_filter(resource_type, allowed_roles, nil, agent_id, _workspace_ids) do
    expr(
      exists(
        Magus.Workspaces.ResourceAccess,
        resource_type == ^resource_type and
          resource_id == parent(id) and
          role in ^allowed_roles and
          grantee_type == :custom_agent and grantee_id == ^agent_id
      )
    )
  end

  defp build_filter(resource_type, allowed_roles, actor_id, nil, workspace_ids) do
    expr(
      exists(
        Magus.Workspaces.ResourceAccess,
        resource_type == ^resource_type and
          resource_id == parent(id) and
          role in ^allowed_roles and
          ((grantee_type == :user and grantee_id == ^actor_id) or
             (grantee_type == :workspace and grantee_id in ^workspace_ids))
      )
    )
  end

  defp build_filter(resource_type, allowed_roles, actor_id, agent_id, []) do
    expr(
      exists(
        Magus.Workspaces.ResourceAccess,
        resource_type == ^resource_type and
          resource_id == parent(id) and
          role in ^allowed_roles and
          ((grantee_type == :user and grantee_id == ^actor_id) or
             (grantee_type == :custom_agent and grantee_id == ^agent_id))
      )
    )
  end

  defp build_filter(resource_type, allowed_roles, actor_id, agent_id, workspace_ids) do
    expr(
      exists(
        Magus.Workspaces.ResourceAccess,
        resource_type == ^resource_type and
          resource_id == parent(id) and
          role in ^allowed_roles and
          ((grantee_type == :user and grantee_id == ^actor_id) or
             (grantee_type == :custom_agent and grantee_id == ^agent_id) or
             (grantee_type == :workspace and grantee_id in ^workspace_ids))
      )
    )
  end

  @doc """
  Returns the workspace ids the user is an active member of.

  Public so other access checks (e.g. checks scoped through a parent resource
  like `Magus.Chat.Message.Checks.WorkspaceConversationAccess`) can build
  filters without duplicating the membership lookup.
  """
  def active_workspace_ids(nil), do: []

  def active_workspace_ids(user_id) do
    import Ash.Query

    Magus.Workspaces.WorkspaceMember
    |> filter(user_id == ^user_id and is_active == true)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.workspace_id)
  end

  @doc """
  Extracts the user id from a User or AiAgent actor.
  """
  def actor_user_id(%Magus.Accounts.User{id: id}), do: id
  def actor_user_id(%Magus.Agents.Support.AiAgent{user_id: id}), do: id
  def actor_user_id(_), do: nil

  @doc """
  Imperative check used in code paths where the filter form isn't convenient.
  """
  def has_access?(resource_type, resource_id, actor, min_role) do
    import Ash.Query

    allowed = roles_satisfying(min_role)
    actor_id = actor_user_id(actor)
    agent_id = actor_agent_id(actor)

    query =
      Magus.Workspaces.ResourceAccess
      |> for_read(:read)
      |> filter(
        resource_type == ^resource_type and
          resource_id == ^resource_id and
          role in ^allowed
      )

    Enum.any?(Ash.read!(query, authorize?: false), fn grant ->
      case grant.grantee_type do
        :user ->
          !is_nil(actor_id) and grant.grantee_id == actor_id

        :custom_agent ->
          !is_nil(agent_id) and grant.grantee_id == agent_id

        :workspace ->
          !is_nil(actor_id) and
            Magus.Checks.Helpers.active_workspace_member?(grant.grantee_id, actor_id)
      end
    end)
  end

  defp actor_agent_id(%Magus.Agents.Support.AiAgent{custom_agent_id: id}), do: id
  defp actor_agent_id(_), do: nil

  defp roles_satisfying(min_role) do
    min_level = Keyword.fetch!(@roles, min_role)
    for {role, level} <- @roles, level >= min_level, do: role
  end
end
