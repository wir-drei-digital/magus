defmodule Magus.SuperBrain.AccessibleGraphs do
  @moduledoc """
  Runtime authority for which FalkorDB graph names an actor is allowed to
  read.

  Retrieval queries ONLY the graphs returned by `for_actor/2`. The crucial
  safety property is that the brain read passes the actor through Ash, so
  `BrainResource`'s `workspace_scoped_policies(:brain)` filters out brains
  the actor cannot see. Same graph name resolves to the same data for the
  same actor regardless of caller, keeping authorization consistent.
  """

  require Ash.Query

  @doc """
  Returns a deduplicated list of graph names readable by the actor in the
  given workspace context.

  ## Options

    * `:workspace_context` — workspace id when the actor is operating
      "inside" a workspace, `nil` for personal context. Workspace graphs
      are only included when the actor is an active member of the
      workspace.

  ## Graphs returned

    * Personal (always): `memories:user:<actor.id>`, `files:user:<actor.id>`,
      `drafts:user:<actor.id>`, plus `brain:<id>` for every personal brain
      the actor can read (`workspace_id IS NULL`).
    * Workspace (when context + active membership): `memories:workspace:<ws>`,
      `files:workspace:<ws>`, plus `brain:<id>` for every brain in the
      workspace the actor can read.
  """
  @spec for_actor(actor :: struct(), opts :: keyword()) :: [String.t()]
  def for_actor(actor, opts \\ []) do
    workspace_context = Keyword.get(opts, :workspace_context)

    (personal_graphs(actor) ++ workspace_graphs(actor, workspace_context))
    |> Enum.uniq()
  end

  @doc """
  Returns the name of the actor's super graph for the given workspace context.

    * `super_graph_for(user, workspace_context: nil)` returns `"super:user:<uid>"`
    * `super_graph_for(user, workspace_context: ws_id)` returns `"super:workspace:<ws>:<uid>"`
  """
  @spec super_graph_for(map(), keyword()) :: String.t()
  def super_graph_for(actor, opts \\ []) do
    case Keyword.get(opts, :workspace_context) do
      nil -> "super:user:#{actor.id}"
      ws_id when is_binary(ws_id) -> "super:workspace:#{ws_id}:#{actor.id}"
    end
  end

  @doc """
  Inverse of `for_actor/2`: given a Layer 1 graph name, returns the list of
  accessors who can read it. Used by `ExtractBase` to fan out
  `BuildSuperIncremental` enqueues after each successful extraction.
  """
  @spec accessors_of(String.t()) :: [
          %{type: :user | :workspace, user_id: String.t(), workspace_id: String.t() | nil}
        ]
  def accessors_of("memories:user:" <> uid), do: [user_accessor(uid)]
  def accessors_of("files:user:" <> uid), do: [user_accessor(uid)]
  def accessors_of("drafts:user:" <> uid), do: [user_accessor(uid)]

  def accessors_of("memories:workspace:" <> ws_id), do: workspace_accessors(ws_id)
  def accessors_of("files:workspace:" <> ws_id), do: workspace_accessors(ws_id)

  def accessors_of("brain:" <> brain_id), do: brain_accessors(brain_id)

  def accessors_of(_), do: []

  defp user_accessor(uid) when is_binary(uid) do
    %{type: :user, user_id: uid, workspace_id: nil}
  end

  defp workspace_accessors(ws_id) do
    Magus.Workspaces.WorkspaceMember
    |> Ash.Query.filter(workspace_id == ^ws_id and is_active == true)
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn member ->
      %{type: :workspace, user_id: member.user_id, workspace_id: ws_id}
    end)
  end

  defp brain_accessors(brain_id) do
    case Ash.get(Magus.Brain.BrainResource, brain_id, authorize?: false) do
      {:ok, brain} ->
        creator = [%{type: :user, user_id: brain.user_id, workspace_id: brain.workspace_id}]

        grantees =
          Magus.Workspaces.ResourceAccess
          |> Ash.Query.filter(resource_type == :brain and resource_id == ^brain_id)
          |> Ash.read!(authorize?: false)
          |> Enum.flat_map(fn grant ->
            case grant.grantee_type do
              :user ->
                [%{type: :user, user_id: grant.grantee_id, workspace_id: brain.workspace_id}]

              :workspace ->
                workspace_accessors(grant.grantee_id)

              _ ->
                []
            end
          end)

        Enum.uniq(creator ++ grantees)

      _ ->
        []
    end
  end

  defp personal_graphs(actor) do
    base = [
      "memories:user:#{actor.id}",
      "files:user:#{actor.id}",
      "drafts:user:#{actor.id}"
    ]

    base ++ readable_brain_graphs(actor, workspace_id: nil)
  end

  defp workspace_graphs(_actor, nil), do: []

  defp workspace_graphs(actor, ws_id) do
    if member_of_workspace?(actor, ws_id) do
      ["memories:workspace:#{ws_id}", "files:workspace:#{ws_id}"] ++
        readable_brain_graphs(actor, workspace_id: ws_id)
    else
      []
    end
  end

  defp readable_brain_graphs(actor, opts) do
    workspace_id = Keyword.get(opts, :workspace_id)

    Magus.Brain.BrainResource
    |> brain_workspace_filter(workspace_id)
    |> Ash.read!(actor: actor)
    |> Enum.map(fn b -> "brain:#{b.id}" end)
  end

  defp brain_workspace_filter(query, nil) do
    Ash.Query.filter(query, is_nil(workspace_id))
  end

  defp brain_workspace_filter(query, ws_id) do
    Ash.Query.filter(query, workspace_id == ^ws_id)
  end

  defp member_of_workspace?(actor, ws_id) do
    Magus.Workspaces.WorkspaceMember
    |> Ash.Query.filter(user_id == ^actor.id and workspace_id == ^ws_id and is_active == true)
    |> Ash.exists?(authorize?: false)
  end
end
