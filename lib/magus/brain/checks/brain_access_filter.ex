defmodule Magus.Brain.Checks.BrainAccessFilter do
  @moduledoc """
  Ash policy filter check that returns a filter restricting records to those
  whose parent brain is accessible to the actor.

  A brain is accessible if any of these hold:

    * the actor owns it (`brain.user_id == actor.id`), or
    * the actor is a workspace admin on the brain's workspace, or
    * a `Magus.Workspaces.ResourceAccess` grant exists at the required minimum
      role with grantee `(grantee_type: :user, actor.id)`,
      `(grantee_type: :custom_agent, actor.custom_agent_id)`, or
      `(grantee_type: :workspace, actor's workspace_ids)`.

  Parameterized via opts to support different relationship paths from the
  target resource to the brain:

    * `path: :direct` — resource has its own `brain_id` attribute
      (e.g. `Magus.Brain.Page`).
    * `path: :via_page` — resource has a `page_id` attribute, brain lives on
      the page (e.g. `Magus.Brain.PageChunk`).
    * `path: :via_source` — resource has a `source_id` attribute pointing to
      a `Magus.Brain.Source` (which carries its own `brain_id`), e.g.
      `Magus.Brain.SourceChunk`.
    * `path: :via_source_page` — resource has a `source_page_id` attribute
      pointing to a `Magus.Brain.Page`, e.g. `Magus.Brain.PageLink` where
      the "source" is the linking page, not a `Magus.Brain.Source` row.
    * `path: :via_brain_page` - resource has a `brain_page` relationship to a
      `Magus.Brain.Page` (which carries its own `brain_id`), e.g.
      `Magus.Plan.Task` attached to a plan page.
    * `path: :via_task_brain_page` - resource reaches the brain through a
      `task` relationship whose `brain_page` carries the `brain_id`, e.g.
      `Magus.Plan.TaskDependency`. Unlike a simple check, this filter-style
      path also authorizes the resource when it is loaded as a relationship
      aggregate (e.g. the `dependencies` count on `Magus.Plan.Task`).

  Supports `min_role` option (default `:viewer`) with role hierarchy:
  `viewer < editor < owner`.

  The set of accessible brain IDs is resolved imperatively (with
  `authorize?: false`) to avoid the limitations of cross-resource
  `exists/2` inside an Ash filter expression.
  """
  use Ash.Policy.FilterCheck

  require Ash.Query

  @role_hierarchy [viewer: 0, editor: 1, owner: 2]

  @impl true
  def describe(opts) do
    min_role = Keyword.get(opts, :min_role, :viewer)
    path = Keyword.fetch!(opts, :path)
    "actor owns brain or has #{min_role}+ access (path: #{path})"
  end

  @doc """
  Runs `fun` with a request-scoped cache of `accessible_brain_ids`, so multiple
  authorized brain-resource reads in one synchronous pass share a single
  resolution instead of re-running the ~5 underlying queries per read.

  The cache is keyed by `(user_id, agent_id, min_role)` and is torn down in an
  `after` block, so it NEVER outlives `fun` — there is no cross-request /
  cross-event authorization staleness. A grant revoked between two passes is
  reflected on the next pass because each pass starts with an empty cache.

  Nesting is safe: only the outermost call owns the scope flag and performs
  teardown; inner calls are no-ops for ownership so they cannot clear the
  outer pass's cache early. When no scope is active the filter resolves
  exactly as before (uncached), so callers outside a scope are unaffected.
  """
  def with_request_cache(fun) do
    already_active? = Process.get(:brain_access_scope_active, false)
    unless already_active?, do: Process.put(:brain_access_scope_active, true)

    try do
      fun.()
    after
      unless already_active? do
        Process.delete(:brain_access_scope_active)

        Process.get_keys()
        |> Enum.filter(&match?({:brain_access_ids, _, _, _}, &1))
        |> Enum.each(&Process.delete/1)
      end
    end
  end

  @impl true
  def filter(actor, _authorizer, opts) do
    min_role = Keyword.get(opts, :min_role, :viewer)
    path = Keyword.fetch!(opts, :path)

    brain_ids = accessible_brain_ids(actor, min_role)

    case path do
      :direct ->
        Ash.Expr.expr(brain_id in ^brain_ids)

      :via_page ->
        Ash.Expr.expr(exists(page, brain_id in ^brain_ids))

      :via_source ->
        Ash.Expr.expr(exists(source, brain_id in ^brain_ids))

      :via_source_page ->
        Ash.Expr.expr(exists(source_page, brain_id in ^brain_ids))

      :via_brain_page ->
        Ash.Expr.expr(exists(brain_page, brain_id in ^brain_ids))

      :via_task_brain_page ->
        Ash.Expr.expr(exists(task.brain_page, brain_id in ^brain_ids))
    end
  end

  # When a `with_request_cache/1` scope is active, memoize the resolved id
  # set per `(user_id, agent_id, min_role)` so repeated authorized reads in
  # the same pass share one resolution. Outside a scope, resolve uncached —
  # identical to the previous behavior.
  defp accessible_brain_ids(nil, _min_role), do: []

  defp accessible_brain_ids(actor, min_role) do
    if Process.get(:brain_access_scope_active, false) do
      key = {:brain_access_ids, actor_user_id(actor), actor_agent_id(actor), min_role}

      case Process.get(key, :__miss__) do
        :__miss__ ->
          ids = compute_accessible_brain_ids(actor, min_role)
          Process.put(key, ids)
          ids

        ids ->
          ids
      end
    else
      compute_accessible_brain_ids(actor, min_role)
    end
  end

  defp compute_accessible_brain_ids(actor, min_role) do
    actor_id = actor_user_id(actor)
    agent_id = actor_agent_id(actor)
    workspace_ids = active_workspace_ids(actor_id)
    admin_workspace_ids = admin_workspace_ids(actor_id)
    allowed_roles = roles_satisfying(min_role)

    owned_ids =
      if actor_id do
        Magus.Brain.BrainResource
        |> Ash.Query.filter(user_id == ^actor_id)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)
      else
        []
      end

    admin_brain_ids =
      if admin_workspace_ids != [] do
        Magus.Brain.BrainResource
        |> Ash.Query.filter(workspace_id in ^admin_workspace_ids)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)
      else
        []
      end

    granted_ids = grant_ids(allowed_roles, actor_id, agent_id, workspace_ids)

    Enum.uniq(owned_ids ++ admin_brain_ids ++ granted_ids)
  end

  defp grant_ids(allowed_roles, actor_id, agent_id, workspace_ids) do
    branches =
      []
      |> maybe_user_branch(actor_id)
      |> maybe_agent_branch(agent_id)
      |> maybe_workspace_branch(workspace_ids)

    case branches do
      [] ->
        []

      [first | rest] ->
        combined = Enum.reduce(rest, first, fn b, acc -> Ash.Expr.expr(^acc or ^b) end)

        Magus.Workspaces.ResourceAccess
        |> Ash.Query.filter(resource_type == :brain and role in ^allowed_roles)
        |> Ash.Query.filter(^combined)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.resource_id)
    end
  end

  defp maybe_user_branch(branches, nil), do: branches

  defp maybe_user_branch(branches, actor_id),
    do: [Ash.Expr.expr(grantee_type == :user and grantee_id == ^actor_id) | branches]

  defp maybe_agent_branch(branches, nil), do: branches

  defp maybe_agent_branch(branches, agent_id),
    do: [Ash.Expr.expr(grantee_type == :custom_agent and grantee_id == ^agent_id) | branches]

  defp maybe_workspace_branch(branches, []), do: branches

  defp maybe_workspace_branch(branches, workspace_ids),
    do: [Ash.Expr.expr(grantee_type == :workspace and grantee_id in ^workspace_ids) | branches]

  defp actor_user_id(%Magus.Accounts.User{id: id}), do: id
  defp actor_user_id(%Magus.Agents.Support.AiAgent{user_id: id}), do: id
  defp actor_user_id(_), do: nil

  defp actor_agent_id(%Magus.Agents.Support.AiAgent{custom_agent_id: id}), do: id
  defp actor_agent_id(_), do: nil

  defp active_workspace_ids(nil), do: []

  defp active_workspace_ids(user_id) do
    Magus.Workspaces.WorkspaceMember
    |> Ash.Query.filter(user_id == ^user_id and is_active == true)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.workspace_id)
  end

  defp admin_workspace_ids(nil), do: []

  defp admin_workspace_ids(user_id) do
    Magus.Workspaces.WorkspaceMember
    |> Ash.Query.filter(user_id == ^user_id and is_active == true and role == :admin)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.workspace_id)
  end

  defp roles_satisfying(min_role) do
    min_level = Keyword.fetch!(@role_hierarchy, min_role)
    for {role, level} <- @role_hierarchy, level >= min_level, do: role
  end
end
