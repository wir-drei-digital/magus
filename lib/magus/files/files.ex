defmodule Magus.Files do
  @moduledoc """
  Files domain: user file uploads and their chunked, pgvector-indexed content
  for semantic retrieval. Uploads enter via multipart `POST /rpc/upload`.
  """

  use Ash.Domain,
    otp_app: :magus,
    extensions: [AshPhoenix, AshTypescript.Rpc]

  # File browser exposure for the SvelteKit workbench (migration iteration 5).
  # Uploads go through POST /rpc/upload (multipart), not an RPC action.
  typescript_rpc do
    resource Magus.Files.File do
      rpc_action :my_library_files, :personal_library_files
      rpc_action :conversation_files, :for_conversation
      rpc_action :files_for_display, :load_for_display
      rpc_action :workspace_library_files, :workspace_library_files
      rpc_action :folder_files, :list_in_folder
      rpc_action :recent_files, :list_recent
      rpc_action :shared_with_me_files, :list_shared_with_me
      rpc_action :trash_files, :list_trash
      rpc_action :template_files, :list_templates
      rpc_action :collection_files, :files_for_collection
      rpc_action :rename_file, :update
      rpc_action :trash_file, :soft_delete
      rpc_action :move_file, :move_to_context
      rpc_action :share_file_to_team, :share_to_team
      rpc_action :unshare_file_from_team, :unshare_from_team
      rpc_action :delete_file, :destroy

      rpc_action :get_file, :read do
        get_by [:id]
      end
    end
  end

  resources do
    resource Magus.Files.File do
      define :create_file, action: :create
      define :create_file_from_content, action: :create_from_content
      define :create_image_file, action: :create_image, args: [:content, :mime_type]
      define :create_video_file, action: :create_video, args: [:content, :mime_type]
      define :create_video_file_from_url, action: :create_video_from_url, args: [:url]
      define :get_file, action: :read, get_by: [:id]
      define :get_file_by_path, action: :by_path, args: [:file_path]
      define :get_files_by_ids, action: :by_ids, args: [:ids]
      define :get_first_image, action: :images_by_ids, args: [:ids]
      define :load_for_display, args: [:ids]
      define :load_llm_content_parts, args: [:ids]
      define :load_first_image_data_uri, args: [:ids]
      define :list_files_for_conversation, action: :for_conversation, args: [:conversation_id]
      define :list_files_for_folder, action: :for_folder, args: [:folder_id]
      define :list_global_files, action: :global_files, args: [:user_id]
      define :list_files_for_workspace, action: :for_workspace, args: [:workspace_id]
      define :list_personal_library_files, action: :personal_library_files
      define :list_templates, action: :list_templates

      define :list_workspace_library_files,
        action: :workspace_library_files,
        args: [:workspace_id]

      define :list_files_in_folder, action: :list_in_folder, args: [:folder_id]
      define :list_recent_files, action: :list_recent, args: [:workspace_id, :since]
      define :list_shared_with_me_files, action: :list_shared_with_me, args: [:workspace_id]
      define :list_trash_files, action: :list_trash, args: [:workspace_id]

      define :list_files_for_collection,
        action: :files_for_collection,
        args: [:knowledge_collection_id]

      define :my_files, action: :my_files
      define :update_file, action: :update
      define :update_file_status, action: :update_status
      define :move_file_to_context, action: :move_to_context
      define :replace_file_content, action: :replace_content, args: [:binary]
      define :delete_file, action: :destroy
      define :create_file_from_connector, action: :create_from_connector
      define :soft_delete_file, action: :soft_delete
      define :update_file_from_connector, action: :update_from_connector

      define :fulltext_search_file, action: :fulltext_search, args: [:query]
    end

    resource Magus.Files.Chunk do
      define :create_chunk, action: :create
      define :bulk_create_chunks, action: :bulk_create

      define :search_chunks,
        action: :semantic_search,
        args: [:query_embedding, :file_ids, :limit]

      define :get_chunks_for_file, action: :for_file, args: [:file_id]

      define :fulltext_search_chunk, action: :fulltext_search, args: [:query]
    end
  end

  @doc """
  Reads the raw binary content of a file from storage.

  Authorizes the actor against the file's `:read` policy before fetching
  the bytes. Returns `{:ok, binary}` on success, `{:error, :forbidden}` if
  the actor cannot read the file, or `{:error, reason}` if storage fails.

  ## Examples

      {:ok, bytes} = Magus.Files.read_binary(file, actor: user)
  """
  def read_binary(%Magus.Files.File{} = file, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    with :ok <- ensure_can_read(file, actor) do
      Magus.Files.Storage.get(file.file_path)
    end
  end

  defp ensure_can_read(file, actor) do
    require Ash.Query

    Magus.Files.File
    |> Ash.Query.filter(id == ^file.id)
    |> Ash.read_one(actor: actor, domain: __MODULE__)
    |> case do
      {:ok, %Magus.Files.File{}} -> :ok
      {:ok, nil} -> {:error, :forbidden}
      {:error, _reason} -> {:error, :forbidden}
    end
  end
end
