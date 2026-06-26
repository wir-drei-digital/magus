defmodule Magus.Files.File.Checks.ActorCanReadFile do
  @moduledoc """
  FilterCheck for read access to a file. Mirrors the File resource's `:read`
  policy: a file is readable when the actor is the creator, owns or is an
  accepted member of the file's conversation, owns or is an active workspace
  member of the file's knowledge collection's source workspace, or holds an
  explicit `Magus.Workspaces.ResourceAccess` grant (`:user`, `:workspace`, or
  `:custom_agent`) at `:viewer` or higher.

  Use directly on `Magus.Files.File`, or on a resource with a `belongs_to :file`
  relationship by passing `via: :<relationship_name>` (e.g. `via: :file` on
  `Magus.Files.Chunk`).

  IMPORTANT: This must stay in sync with the File resource's `policies` block.
  Notably, being an active workspace member of the file's `workspace_id` is
  NOT sufficient — a `ResourceAccess` grant is required for private workspace
  files. Workspace admins are covered by `Magus.Checks.ActorCanManageWorkspaceResource`
  at the policy layer rather than here.
  """

  use Ash.Policy.FilterCheck

  @grant_roles [:viewer, :editor, :owner]

  @impl true
  def describe(_opts), do: "actor can read the file"

  @impl true
  def filter(actor, _authorizer, opts) do
    actor_id = actor_user_id(actor)
    agent_id = actor_agent_id(actor)
    workspace_ids = active_workspace_ids(actor_id)

    case opts[:via] do
      nil ->
        top_level(actor_id, agent_id, workspace_ids)

      relationship when is_atom(relationship) ->
        via(relationship, actor_id, agent_id, workspace_ids)
    end
  end

  # ---------------------------------------------------------------------------
  # Top-level (resource == Magus.Files.File)
  # ---------------------------------------------------------------------------

  defp top_level(nil, nil, _workspace_ids), do: expr(false)

  defp top_level(actor_id, nil, []) do
    expr(
      user_id == ^actor_id or
        (not is_nil(conversation_id) and conversation.user_id == ^actor_id) or
        (not is_nil(conversation_id) and
           exists(
             conversation.members,
             user_id == ^actor_id and not is_nil(accepted_at)
           )) or
        (not is_nil(knowledge_collection_id) and
           knowledge_collection.knowledge_source.user_id == ^actor_id) or
        (not is_nil(knowledge_collection_id) and
           not is_nil(knowledge_collection.knowledge_source.workspace_id) and
           exists(
             knowledge_collection.knowledge_source.workspace.members,
             is_active == true and user_id == ^actor_id
           )) or
        exists(
          Magus.Workspaces.ResourceAccess,
          resource_type == :file and
            resource_id == parent(id) and
            role in ^@grant_roles and
            grantee_type == :user and
            grantee_id == ^actor_id
        )
    )
  end

  defp top_level(actor_id, nil, workspace_ids) do
    expr(
      user_id == ^actor_id or
        (not is_nil(conversation_id) and conversation.user_id == ^actor_id) or
        (not is_nil(conversation_id) and
           exists(
             conversation.members,
             user_id == ^actor_id and not is_nil(accepted_at)
           )) or
        (not is_nil(knowledge_collection_id) and
           knowledge_collection.knowledge_source.user_id == ^actor_id) or
        (not is_nil(knowledge_collection_id) and
           not is_nil(knowledge_collection.knowledge_source.workspace_id) and
           exists(
             knowledge_collection.knowledge_source.workspace.members,
             is_active == true and user_id == ^actor_id
           )) or
        exists(
          Magus.Workspaces.ResourceAccess,
          resource_type == :file and
            resource_id == parent(id) and
            role in ^@grant_roles and
            ((grantee_type == :user and grantee_id == ^actor_id) or
               (grantee_type == :workspace and grantee_id in ^workspace_ids))
        )
    )
  end

  defp top_level(nil, agent_id, _workspace_ids) do
    expr(
      exists(
        Magus.Workspaces.ResourceAccess,
        resource_type == :file and
          resource_id == parent(id) and
          role in ^@grant_roles and
          grantee_type == :custom_agent and
          grantee_id == ^agent_id
      )
    )
  end

  defp top_level(actor_id, agent_id, []) do
    expr(
      user_id == ^actor_id or
        (not is_nil(conversation_id) and conversation.user_id == ^actor_id) or
        (not is_nil(conversation_id) and
           exists(
             conversation.members,
             user_id == ^actor_id and not is_nil(accepted_at)
           )) or
        (not is_nil(knowledge_collection_id) and
           knowledge_collection.knowledge_source.user_id == ^actor_id) or
        (not is_nil(knowledge_collection_id) and
           not is_nil(knowledge_collection.knowledge_source.workspace_id) and
           exists(
             knowledge_collection.knowledge_source.workspace.members,
             is_active == true and user_id == ^actor_id
           )) or
        exists(
          Magus.Workspaces.ResourceAccess,
          resource_type == :file and
            resource_id == parent(id) and
            role in ^@grant_roles and
            ((grantee_type == :user and grantee_id == ^actor_id) or
               (grantee_type == :custom_agent and grantee_id == ^agent_id))
        )
    )
  end

  defp top_level(actor_id, agent_id, workspace_ids) do
    expr(
      user_id == ^actor_id or
        (not is_nil(conversation_id) and conversation.user_id == ^actor_id) or
        (not is_nil(conversation_id) and
           exists(
             conversation.members,
             user_id == ^actor_id and not is_nil(accepted_at)
           )) or
        (not is_nil(knowledge_collection_id) and
           knowledge_collection.knowledge_source.user_id == ^actor_id) or
        (not is_nil(knowledge_collection_id) and
           not is_nil(knowledge_collection.knowledge_source.workspace_id) and
           exists(
             knowledge_collection.knowledge_source.workspace.members,
             is_active == true and user_id == ^actor_id
           )) or
        exists(
          Magus.Workspaces.ResourceAccess,
          resource_type == :file and
            resource_id == parent(id) and
            role in ^@grant_roles and
            ((grantee_type == :user and grantee_id == ^actor_id) or
               (grantee_type == :workspace and grantee_id in ^workspace_ids) or
               (grantee_type == :custom_agent and grantee_id == ^agent_id))
        )
    )
  end

  # ---------------------------------------------------------------------------
  # Via :file (resource has a belongs_to :file with foreign key file_id).
  #
  # Non-grant branches use `exists(file, ...)` to traverse the file's fields.
  # Grant lookups use `parent(file_id)` against the parent resource's foreign
  # key, avoiding nested-exists `parent` ambiguity. Currently only `:file` is
  # supported; add an explicit clause if another belongs_to target is needed.
  # ---------------------------------------------------------------------------

  defp via(:file, nil, nil, _workspace_ids), do: expr(false)

  defp via(:file, actor_id, nil, []) do
    expr(
      exists(
        file,
        user_id == ^actor_id or
          (not is_nil(conversation_id) and conversation.user_id == ^actor_id) or
          (not is_nil(conversation_id) and
             exists(
               conversation.members,
               user_id == ^actor_id and not is_nil(accepted_at)
             )) or
          (not is_nil(knowledge_collection_id) and
             knowledge_collection.knowledge_source.user_id == ^actor_id) or
          (not is_nil(knowledge_collection_id) and
             not is_nil(knowledge_collection.knowledge_source.workspace_id) and
             exists(
               knowledge_collection.knowledge_source.workspace.members,
               is_active == true and user_id == ^actor_id
             ))
      ) or
        exists(
          Magus.Workspaces.ResourceAccess,
          resource_type == :file and
            resource_id == parent(file_id) and
            role in ^@grant_roles and
            grantee_type == :user and
            grantee_id == ^actor_id
        )
    )
  end

  defp via(:file, actor_id, nil, workspace_ids) do
    expr(
      exists(
        file,
        user_id == ^actor_id or
          (not is_nil(conversation_id) and conversation.user_id == ^actor_id) or
          (not is_nil(conversation_id) and
             exists(
               conversation.members,
               user_id == ^actor_id and not is_nil(accepted_at)
             )) or
          (not is_nil(knowledge_collection_id) and
             knowledge_collection.knowledge_source.user_id == ^actor_id) or
          (not is_nil(knowledge_collection_id) and
             not is_nil(knowledge_collection.knowledge_source.workspace_id) and
             exists(
               knowledge_collection.knowledge_source.workspace.members,
               is_active == true and user_id == ^actor_id
             ))
      ) or
        exists(
          Magus.Workspaces.ResourceAccess,
          resource_type == :file and
            resource_id == parent(file_id) and
            role in ^@grant_roles and
            ((grantee_type == :user and grantee_id == ^actor_id) or
               (grantee_type == :workspace and grantee_id in ^workspace_ids))
        )
    )
  end

  defp via(:file, nil, agent_id, _workspace_ids) do
    expr(
      exists(
        Magus.Workspaces.ResourceAccess,
        resource_type == :file and
          resource_id == parent(file_id) and
          role in ^@grant_roles and
          grantee_type == :custom_agent and
          grantee_id == ^agent_id
      )
    )
  end

  defp via(:file, actor_id, agent_id, []) do
    expr(
      exists(
        file,
        user_id == ^actor_id or
          (not is_nil(conversation_id) and conversation.user_id == ^actor_id) or
          (not is_nil(conversation_id) and
             exists(
               conversation.members,
               user_id == ^actor_id and not is_nil(accepted_at)
             )) or
          (not is_nil(knowledge_collection_id) and
             knowledge_collection.knowledge_source.user_id == ^actor_id) or
          (not is_nil(knowledge_collection_id) and
             not is_nil(knowledge_collection.knowledge_source.workspace_id) and
             exists(
               knowledge_collection.knowledge_source.workspace.members,
               is_active == true and user_id == ^actor_id
             ))
      ) or
        exists(
          Magus.Workspaces.ResourceAccess,
          resource_type == :file and
            resource_id == parent(file_id) and
            role in ^@grant_roles and
            ((grantee_type == :user and grantee_id == ^actor_id) or
               (grantee_type == :custom_agent and grantee_id == ^agent_id))
        )
    )
  end

  defp via(:file, actor_id, agent_id, workspace_ids) do
    expr(
      exists(
        file,
        user_id == ^actor_id or
          (not is_nil(conversation_id) and conversation.user_id == ^actor_id) or
          (not is_nil(conversation_id) and
             exists(
               conversation.members,
               user_id == ^actor_id and not is_nil(accepted_at)
             )) or
          (not is_nil(knowledge_collection_id) and
             knowledge_collection.knowledge_source.user_id == ^actor_id) or
          (not is_nil(knowledge_collection_id) and
             not is_nil(knowledge_collection.knowledge_source.workspace_id) and
             exists(
               knowledge_collection.knowledge_source.workspace.members,
               is_active == true and user_id == ^actor_id
             ))
      ) or
        exists(
          Magus.Workspaces.ResourceAccess,
          resource_type == :file and
            resource_id == parent(file_id) and
            role in ^@grant_roles and
            ((grantee_type == :user and grantee_id == ^actor_id) or
               (grantee_type == :workspace and grantee_id in ^workspace_ids) or
               (grantee_type == :custom_agent and grantee_id == ^agent_id))
        )
    )
  end

  defp via(other, _, _, _) do
    raise ArgumentError,
          "ActorCanReadFile :via supports only :file currently, got #{inspect(other)}. " <>
            "Add an explicit clause if another belongs_to target is required."
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp active_workspace_ids(nil), do: []

  defp active_workspace_ids(user_id) do
    require Ash.Query

    Magus.Workspaces.WorkspaceMember
    |> Ash.Query.filter(user_id == ^user_id and is_active == true)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.workspace_id)
  end

  defp actor_user_id(%Magus.Accounts.User{id: id}), do: id
  defp actor_user_id(%Magus.Agents.Support.AiAgent{user_id: id}), do: id
  defp actor_user_id(_), do: nil

  defp actor_agent_id(%Magus.Agents.Support.AiAgent{custom_agent_id: id}), do: id
  defp actor_agent_id(_), do: nil
end
