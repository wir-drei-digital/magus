defmodule Magus.Knowledge do
  use Ash.Domain, otp_app: :magus, extensions: [AshTypescript.Rpc]

  typescript_rpc do
    # Files-mode "Connected sources" nav group (classic parity); the files
    # for a collection are already exposed as collection_files.
    resource Magus.Knowledge.KnowledgeCollection do
      rpc_action :my_knowledge_collections, :personal_collections
      rpc_action :workspace_knowledge_collections, :list_for_workspace
    end

    resource Magus.Knowledge.KnowledgeSource do
      rpc_action :list_knowledge_sources, :for_user
      rpc_action :disconnect_knowledge_source, :destroy
    end
  end

  resources do
    resource Magus.Knowledge.KnowledgeSource do
      define :create_source, action: :create
      define :update_source_status, action: :update_status
      define :get_source, action: :read, get_by: [:id]
      define :list_sources_for_user, action: :for_user
      define :list_sources_for_workspace, action: :for_workspace, args: [:workspace_id]
      define :update_source_auth_config, action: :update_auth_config
      define :destroy_source, action: :destroy
    end

    resource Magus.Knowledge.KnowledgeCollection do
      define :create_collection, action: :create, args: [:knowledge_source_id]
      define :update_sync_status, action: :update_sync_status
      define :trigger_full_sync, action: :full_sync
      define :get_collection, action: :read, get_by: [:id]
      define :list_collections_for_source, action: :for_source, args: [:knowledge_source_id]
      define :list_personal_collections, action: :personal_collections
      define :list_workspace_collections, action: :list_for_workspace, args: [:workspace_id]
      define :destroy_collection, action: :destroy
    end
  end

  @doc """
  Returns file IDs accessible to the given grantees via `Magus.Workspaces.ResourceAccess`.

  Combines direct `:file` grants and `:knowledge_collection` grants
  (expanded to the files inside each granted collection).

  Options (all optional):
    - user_id: UUID of the user
    - workspace_id: UUID of the workspace
    - custom_agent_id: UUID of the custom agent
  """
  def get_accessible_file_ids(opts) do
    grantees =
      []
      |> then(fn acc ->
        case Keyword.get(opts, :user_id) do
          nil -> acc
          id -> [{:user, id} | acc]
        end
      end)
      |> then(fn acc ->
        case Keyword.get(opts, :workspace_id) do
          nil -> acc
          id -> [{:workspace, id} | acc]
        end
      end)
      |> then(fn acc ->
        case Keyword.get(opts, :custom_agent_id) do
          nil -> acc
          id -> [{:custom_agent, id} | acc]
        end
      end)

    if Enum.empty?(grantees) do
      {:ok, []}
    else
      require Ash.Query

      grantee_ids = Enum.map(grantees, fn {_type, id} -> id end)

      {:ok, all_records} =
        Magus.Workspaces.ResourceAccess
        |> Ash.Query.filter(
          grantee_id in ^grantee_ids and
            resource_type in [:file, :knowledge_collection]
        )
        |> Ash.read(authorize?: false)

      # Match (grantee_type, grantee_id) pairs in Elixir
      access_records =
        Enum.filter(all_records, fn record ->
          Enum.any?(grantees, fn {type, id} ->
            record.grantee_id == id and record.grantee_type == type
          end)
        end)

      {collection_grants, file_grants} =
        Enum.split_with(access_records, fn record ->
          record.resource_type == :knowledge_collection
        end)

      direct_file_ids =
        file_grants
        |> Enum.map(& &1.resource_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      collection_ids =
        collection_grants
        |> Enum.map(& &1.resource_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      collection_file_ids =
        if Enum.empty?(collection_ids) do
          []
        else
          Magus.Files.File
          |> Ash.Query.filter(
            knowledge_collection_id in ^collection_ids and
              status == :ready and
              is_nil(deleted_at)
          )
          |> Ash.Query.select([:id])
          |> Ash.read!(authorize?: false)
          |> Enum.map(& &1.id)
        end

      {:ok, Enum.uniq(direct_file_ids ++ collection_file_ids)}
    end
  end
end
