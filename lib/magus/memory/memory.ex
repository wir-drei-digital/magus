defmodule Magus.Memory do
  @moduledoc """
  Domain for persistent memory storage with scope hierarchy.

  Memories are topic-based key-value stores that persist across conversation
  sessions. Memories can be:

  - **Local** - Scoped to a specific conversation
  - **Agent** - Scoped to a custom agent, available across that agent's conversations
  - **User** - Scoped to the user, available across all conversations

  Each memory has a confidence score, kind classification, and optional source tracking.
  Memories form Hebbian associations (weighted edges) that are reinforced on co-retrieval.
  Each memory maintains a version history for debugging and rollback purposes.
  """

  use Ash.Domain, otp_app: :magus, extensions: [AshTypescript.Rpc]

  typescript_rpc do
    resource Magus.Memory.Memory do
      rpc_action :list_user_memories, :user_for_user
      rpc_action :deactivate_user_memory, :deactivate
    end

    resource Magus.Memory.UserProfile do
      rpc_action :get_user_profile, :for_bucket
      rpc_action :clear_user_profile, :clear
    end
  end

  @doc """
  Bulk-update last_accessed_at for the given memory IDs.

  Uses direct SQL to avoid triggering CreateVersion/BroadcastMemoryEvent/optimistic_lock.
  """
  # Intentionally raw SQL: this must NOT run through the :set/:deactivate
  # actions, which would create a MemoryVersion, broadcast PubSub, and bump
  # lock_version on every semantic-retrieval and search-tool touch.
  def touch_accessed(memory_ids) when is_list(memory_ids) and memory_ids != [] do
    Magus.Repo.query!(
      "UPDATE memories SET last_accessed_at = $1 WHERE id = ANY($2::uuid[])",
      [
        DateTime.utc_now(),
        Enum.map(memory_ids, fn id ->
          {:ok, binary} = Ecto.UUID.dump(to_string(id))
          binary
        end)
      ]
    )

    :ok
  end

  def touch_accessed([]), do: :ok

  @doc """
  Returns the workspace_id for the given conversation_id, or nil if the
  conversation is in personal context (or doesn't exist).

  Used by agent actions and reactors to derive the workspace bucket
  when calling user-scope memory operations.
  """
  def workspace_id_for_conversation(nil), do: nil

  def workspace_id_for_conversation(conversation_id) do
    require Ash.Query

    case Magus.Chat.Conversation
         |> Ash.Query.filter(id == ^conversation_id)
         |> Ash.Query.select([:workspace_id])
         |> Ash.read_one(authorize?: false) do
      {:ok, %{workspace_id: ws}} -> ws
      _ -> nil
    end
  end

  @doc """
  Tagged variant of `workspace_id_for_conversation/1`.

  Distinguishes "personal conversation" ({:ok, nil}) from "conversation does
  not exist" ({:error, :not_found}) so tool callers can refuse to silently
  write to the personal bucket on a bad conversation id.
  """
  @spec fetch_workspace_id_for_conversation(String.t() | nil) ::
          {:ok, String.t() | nil} | {:error, :not_found}
  def fetch_workspace_id_for_conversation(nil), do: {:error, :not_found}

  def fetch_workspace_id_for_conversation(conversation_id) do
    require Ash.Query

    case Magus.Chat.Conversation
         |> Ash.Query.filter(id == ^conversation_id)
         |> Ash.Query.select([:workspace_id])
         |> Ash.read_one(authorize?: false) do
      {:ok, %{workspace_id: ws}} -> {:ok, ws}
      {:ok, nil} -> {:error, :not_found}
      _ -> {:error, :not_found}
    end
  end

  resources do
    resource Magus.Memory.Memory do
      # Local (conversation-scoped) memory operations
      define :create_memory, action: :create, args: [:conversation_id, :user_id, :name]
      define :set_memory, action: :set, args: [:content]
      define :clear_memory, action: :clear
      define :deactivate_memory, action: :deactivate
      define :get_memory, action: :read, get_by: [:id]
      define :list_memories_for_conversation, action: :for_conversation, args: [:conversation_id]
      define :get_most_recent_memory, action: :most_recent, args: [:conversation_id]
      define :get_memory_by_name, action: :by_name, args: [:conversation_id, :name]

      define :search_memories,
        action: :semantic_search,
        args: [:conversation_id, :query_embedding]

      # User (user-scoped) memory operations
      define :create_user_memory, action: :create_user, args: [:user_id, :workspace_id, :name]
      define :list_user_memories, action: :user_for_user, args: [:workspace_id]
      define :get_user_memory_by_name, action: :user_by_name, args: [:workspace_id, :name]

      define :search_user_memories,
        action: :semantic_search_user,
        args: [:user_id, :workspace_id, :query_embedding]

      # Scope management
      define :promote_memory_to_user, action: :promote_to_user

      # Agent (custom-agent-scoped) memory operations
      define :create_agent_memory, action: :create_agent, args: [:user_id, :custom_agent_id]
      define :list_agent_memories, action: :for_agent, args: [:custom_agent_id]
      define :get_agent_memory_by_name, action: :agent_by_name, args: [:custom_agent_id, :name]

      define :search_agent_memories,
        action: :semantic_search_agent,
        args: [:custom_agent_id, :query_embedding]

      # Top memories by recency
      define :list_top_local, action: :top_local_by_recency, args: [:conversation_id]
      define :list_top_user, action: :top_user_by_recency, args: [:workspace_id]
    end

    resource Magus.Memory.MemoryVersion do
      define :create_memory_version, action: :create
      define :list_versions_for_memory, action: :for_memory, args: [:memory_id]
    end

    resource Magus.Memory.MemorySource do
      define :create_memory_source, action: :create, args: [:memory_id]
    end

    resource Magus.Memory.MemoryAssociation do
      define :create_memory_association, action: :create, args: [:memory_a_id, :memory_b_id]
      define :reinforce_association, action: :reinforce
      define :get_associations_for_memory, action: :for_memory, args: [:memory_id]

      define :get_association_between,
        action: :between,
        args: [:memory_a_id, :memory_b_id],
        get?: true
    end

    resource Magus.Memory.UserProfile do
      define :create_user_profile, action: :create, args: [:user_id, :workspace_id]
      define :get_user_profile, action: :for_bucket, args: [:user_id, :workspace_id]
      define :set_profile_document, action: :set_document
      define :add_profile_note, action: :add_note, args: [:note]
    end

    resource Magus.Memory.UserProfileVersion do
      define :create_profile_version, action: :create
      define :list_profile_versions, action: :for_profile, args: [:user_profile_id]
    end
  end
end
