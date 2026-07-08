defmodule Magus.Memory.Memory do
  @moduledoc """
  A persistent memory store with scope hierarchy.

  Memories allow AI agents to store and retrieve structured information
  that persists across conversation sessions. Memories can be either:

  - **Local** - Scoped to a specific conversation (e.g., project context, task lists)
  - **Global** - Scoped to the user, available across all conversations (e.g., preferences, coding style)
  - **Agent** - Scoped to a custom agent, available across all conversations using that agent

  Features:
  - Topic-based organization (name identifies the memory topic)
  - Versioned history for debugging/rollback
  - Semantic search via summary embeddings
  - Optimistic locking for concurrent access
  - Scope hierarchy for cross-conversation learning
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Memory,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOban, AshTypescript.Resource],
    authorizers: [Ash.Policy.Authorizer]

  import AshOban.Changes.BuiltinChanges, only: [run_oban_trigger: 1]

  require Ash.Query

  @doc false
  # Enqueues a Super Brain extraction job for this memory after the row
  # commits. `:local` memories are filtered out because they are not
  # extracted into a graph (see ExtractMemory.route/1).
  def enqueue_super_brain_extraction(%{scope: :local}), do: :ok

  def enqueue_super_brain_extraction(%{id: id, scope: scope})
      when scope in [:user, :agent] do
    if Magus.SuperBrain.enabled?() do
      %{"resource_id" => id}
      |> Magus.SuperBrain.Workers.ExtractMemory.new()
      |> Oban.insert()
    else
      :ok
    end
  end

  def enqueue_super_brain_extraction(_), do: :ok

  @doc false
  # Local memories are never extracted into a graph, so there is nothing to
  # retract for them.
  def enqueue_super_brain_retraction(%{scope: :local}), do: :ok

  def enqueue_super_brain_retraction(%{id: id, scope: scope} = memory)
      when scope in [:user, :agent] do
    if Magus.SuperBrain.enabled?() do
      graph_name =
        case Magus.SuperBrain.Workers.ExtractMemory.route(memory) do
          {:ok, graph_name, _extra} -> graph_name
          _ -> nil
        end

      %{"resource_type" => "memory", "resource_id" => id, "graph_name" => graph_name}
      |> Magus.SuperBrain.Workers.RetractResource.new()
      |> Oban.insert()
    else
      :ok
    end
  end

  def enqueue_super_brain_retraction(_), do: :ok

  postgres do
    table "memories"
    repo Magus.Repo

    identity_wheres_to_sql unique_name_per_conversation: "is_active = true AND scope = 'local'",
                           unique_user_name_per_user: "is_active = true AND scope = 'user'",
                           unique_name_per_agent: "is_active = true AND scope = 'agent'"

    references do
      reference :workspace, on_delete: :delete
    end

    custom_indexes do
      index [:workspace_id, :user_id], name: "memories_workspace_id_user_id_index"
    end

    custom_statements do
      statement :local_requires_conversation do
        up "ALTER TABLE memories ADD CONSTRAINT memories_local_requires_conversation CHECK (scope IN ('user', 'agent') OR conversation_id IS NOT NULL)"
        down "ALTER TABLE memories DROP CONSTRAINT IF EXISTS memories_local_requires_conversation"
      end

      statement :agent_scope_requires_agent do
        up "ALTER TABLE memories ADD CONSTRAINT memories_agent_scope_requires_agent CHECK (scope != 'agent' OR custom_agent_id IS NOT NULL)"
        down "ALTER TABLE memories DROP CONSTRAINT IF EXISTS memories_agent_scope_requires_agent"
      end
    end
  end

  oban do
    triggers do
      trigger :generate_embedding do
        action :generate_embedding
        queue :memory_extraction
        scheduler_cron false
        where expr(not is_nil(summary))
        worker_module_name Magus.Memory.Memory.Workers.GenerateEmbedding
        scheduler_module_name Magus.Memory.Memory.Schedulers.GenerateEmbedding
      end
    end
  end

  typescript do
    type_name "Memory"
  end

  actions do
    read :read do
      primary? true
      pagination keyset?: true, required?: false
    end

    create :create do
      description "Create a local (conversation-scoped) memory"
      accept [:name, :summary, :content, :confidence, :kind, :structured_data]

      argument :conversation_id, :uuid, allow_nil?: false
      argument :user_id, :uuid, allow_nil?: false

      change set_attribute(:conversation_id, arg(:conversation_id))
      change set_attribute(:user_id, arg(:user_id))
      change set_attribute(:scope, :local)
      change Magus.Memory.Memory.Changes.DeriveWorkspaceFromConversation
      change Magus.Memory.Memory.Changes.CreateVersion
      change run_oban_trigger(:generate_embedding)
      change Magus.Memory.Memory.Changes.BroadcastMemoryEvent
    end

    create :create_user do
      description "Create a user-scoped memory"
      accept [:name, :summary, :content, :confidence, :kind, :structured_data]

      argument :user_id, :uuid, allow_nil?: false
      argument :workspace_id, :uuid, allow_nil?: true

      change set_attribute(:user_id, arg(:user_id))
      change set_attribute(:workspace_id, arg(:workspace_id))
      change set_attribute(:scope, :user)
      change set_attribute(:conversation_id, nil)
      change Magus.Memory.Memory.Changes.CreateVersion
      change run_oban_trigger(:generate_embedding)
      change Magus.Memory.Memory.Changes.BroadcastMemoryEvent

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _cs, memory ->
          enqueue_super_brain_extraction(memory)
          {:ok, memory}
        end)
      end
    end

    create :create_agent do
      description "Create an agent-scoped memory"
      accept [:name, :summary, :content, :confidence, :kind, :structured_data]

      argument :user_id, :uuid, allow_nil?: false
      argument :custom_agent_id, :uuid, allow_nil?: false

      change set_attribute(:user_id, arg(:user_id))
      change set_attribute(:custom_agent_id, arg(:custom_agent_id))
      change set_attribute(:scope, :agent)
      change set_attribute(:conversation_id, nil)
      change Magus.Memory.Memory.Changes.DeriveWorkspaceFromCustomAgent
      change Magus.Memory.Memory.Changes.CreateVersion
      change run_oban_trigger(:generate_embedding)
      change Magus.Memory.Memory.Changes.BroadcastMemoryEvent

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _cs, memory ->
          enqueue_super_brain_extraction(memory)
          {:ok, memory}
        end)
      end
    end

    update :set do
      accept [:content, :summary, :confidence, :kind, :structured_data]
      require_atomic? false

      change Magus.Memory.Memory.Changes.CreateVersion
      change run_oban_trigger(:generate_embedding)
      change Magus.Memory.Memory.Changes.BroadcastMemoryEvent

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _cs, memory ->
          enqueue_super_brain_extraction(memory)
          {:ok, memory}
        end)
      end
    end

    update :generate_embedding do
      description "Generate embedding for memory summary (triggered by AshOban)"
      require_atomic? false

      change Magus.Memory.Memory.Changes.GenerateEmbedding
    end

    update :clear do
      require_atomic? false
      change set_attribute(:content, %{})
      change Magus.Memory.Memory.Changes.CreateVersion
      change Magus.Memory.Memory.Changes.BroadcastMemoryEvent
    end

    destroy :destroy do
      primary? true
      require_atomic? false

      change Magus.Memory.Memory.Changes.BroadcastMemoryEvent

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _cs, memory ->
          enqueue_super_brain_retraction(memory)
          {:ok, memory}
        end)
      end
    end

    read :for_conversation do
      description "List local memories for a conversation"
      argument :conversation_id, :uuid, allow_nil?: false

      filter expr(
               conversation_id == ^arg(:conversation_id) and is_active == true and scope == :local
             )

      prepare build(sort: [updated_at: :desc])
    end

    read :user_for_user do
      description "List user-scoped memories for the current user, scoped to a workspace"
      argument :workspace_id, :uuid, allow_nil?: true

      filter expr(
               user_id == ^actor(:id) and is_active == true and scope == :user and
                 ((is_nil(workspace_id) and is_nil(^arg(:workspace_id))) or
                    workspace_id == ^arg(:workspace_id))
             )

      prepare build(sort: [updated_at: :desc])
    end

    read :most_recent do
      argument :conversation_id, :uuid, allow_nil?: false
      get? true

      filter expr(conversation_id == ^arg(:conversation_id) and is_active == true)
      prepare build(sort: [updated_at: :desc], limit: 1)
    end

    read :by_name do
      description "Find a local memory by name within a conversation"
      argument :conversation_id, :uuid, allow_nil?: false
      argument :name, :string, allow_nil?: false
      get? true

      filter expr(
               conversation_id == ^arg(:conversation_id) and
                 name == ^arg(:name) and
                 is_active == true and
                 scope == :local
             )
    end

    read :user_by_name do
      description "Find a user-scoped memory by name in a specific workspace bucket"
      argument :workspace_id, :uuid, allow_nil?: true
      argument :name, :string, allow_nil?: false
      get? true

      filter expr(
               user_id == ^actor(:id) and
                 name == ^arg(:name) and
                 is_active == true and
                 scope == :user and
                 ((is_nil(workspace_id) and is_nil(^arg(:workspace_id))) or
                    workspace_id == ^arg(:workspace_id))
             )
    end

    read :top_local_by_recency do
      description "Top local memories for a conversation, sorted by most recently updated"
      argument :conversation_id, :uuid, allow_nil?: false

      filter expr(
               conversation_id == ^arg(:conversation_id) and
                 is_active == true and
                 scope == :local
             )

      prepare build(sort: [updated_at: :desc], limit: 3)
    end

    read :top_user_by_recency do
      description "Top user-scoped memories for the current user in a workspace"
      argument :workspace_id, :uuid, allow_nil?: true

      filter expr(
               user_id == ^actor(:id) and
                 is_active == true and
                 scope == :user and
                 ((is_nil(workspace_id) and is_nil(^arg(:workspace_id))) or
                    workspace_id == ^arg(:workspace_id))
             )

      prepare build(sort: [updated_at: :desc], limit: 3)
    end

    read :semantic_search do
      description "Semantic search within a conversation's local memories"
      argument :conversation_id, :uuid, allow_nil?: false
      argument :query_embedding, {:array, :float}, allow_nil?: false
      argument :limit, :integer, default: 5

      filter expr(
               conversation_id == ^arg(:conversation_id) and is_active == true and scope == :local
             )

      prepare fn query, _context ->
        embedding = Ash.Query.get_argument(query, :query_embedding)
        limit_val = Ash.Query.get_argument(query, :limit)
        calc_args = %{query_embedding: embedding}

        query
        |> Ash.Query.filter(not is_nil(summary_embedding))
        |> Ash.Query.load(vector_distance: calc_args)
        |> Ash.Query.sort({:vector_distance, {calc_args, :asc}})
        |> Ash.Query.limit(limit_val)
      end
    end

    read :semantic_search_user do
      description "Semantic search within a user's user-scoped memories in a workspace"
      argument :user_id, :uuid, allow_nil?: false
      argument :workspace_id, :uuid, allow_nil?: true
      argument :query_embedding, {:array, :float}, allow_nil?: false
      argument :limit, :integer, default: 5

      filter expr(
               user_id == ^arg(:user_id) and is_active == true and scope == :user and
                 ((is_nil(workspace_id) and is_nil(^arg(:workspace_id))) or
                    workspace_id == ^arg(:workspace_id))
             )

      prepare fn query, _context ->
        embedding = Ash.Query.get_argument(query, :query_embedding)
        limit_val = Ash.Query.get_argument(query, :limit)
        calc_args = %{query_embedding: embedding}

        query
        |> Ash.Query.filter(not is_nil(summary_embedding))
        |> Ash.Query.load(vector_distance: calc_args)
        |> Ash.Query.sort({:vector_distance, {calc_args, :asc}})
        |> Ash.Query.limit(limit_val)
      end
    end

    read :for_agent do
      description "List agent-scoped memories"
      argument :custom_agent_id, :uuid, allow_nil?: false

      filter expr(
               custom_agent_id == ^arg(:custom_agent_id) and is_active == true and scope == :agent
             )

      prepare build(sort: [updated_at: :desc])
    end

    read :agent_by_name do
      description "Find an agent-scoped memory by name"
      argument :custom_agent_id, :uuid, allow_nil?: false
      argument :name, :string, allow_nil?: false
      get? true

      filter expr(
               custom_agent_id == ^arg(:custom_agent_id) and
                 name == ^arg(:name) and
                 is_active == true and
                 scope == :agent
             )
    end

    read :semantic_search_agent do
      description "Semantic search within an agent's memories"
      argument :custom_agent_id, :uuid, allow_nil?: false
      argument :query_embedding, {:array, :float}, allow_nil?: false
      argument :limit, :integer, default: 5

      filter expr(
               custom_agent_id == ^arg(:custom_agent_id) and is_active == true and scope == :agent
             )

      prepare fn query, _context ->
        embedding = Ash.Query.get_argument(query, :query_embedding)
        limit_val = Ash.Query.get_argument(query, :limit)
        calc_args = %{query_embedding: embedding}

        query
        |> Ash.Query.filter(not is_nil(summary_embedding))
        |> Ash.Query.load(vector_distance: calc_args)
        |> Ash.Query.sort({:vector_distance, {calc_args, :asc}})
        |> Ash.Query.limit(limit_val)
      end
    end
  end

  policies do
    # AI Agent can perform all memory operations for extraction
    bypass action_type([:read, :create, :update, :destroy]) do
      authorize_if Magus.Checks.IsAiAgent
    end

    # Users can access memories for conversations they own or are members of
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))

      authorize_if expr(
                     exists(
                       conversation.members,
                       user_id == ^actor(:id) and not is_nil(accepted_at)
                     )
                   )
    end

    # For create, check that the user_id argument matches the actor
    policy action_type(:create) do
      authorize_if Magus.Memory.Memory.Checks.UserIdMatchesActor
    end

    # Only the owner can modify existing memories
    policy action_type([:update, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  changes do
    change optimistic_lock(:lock_version), on: [:update]
  end

  validations do
    validate {Magus.Memory.Memory.Validations.ContentSize, max_chars: 8_000},
      on: [:create, :update],
      where: [changing(:content)]

    validate {Magus.Memory.Memory.Validations.SummaryLength, max_chars: 500},
      on: [:create, :update],
      where: [changing(:summary)]
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :summary, :string, public?: true
    attribute :summary_embedding, Magus.Files.Types.Vector
    attribute :content, :map, default: %{}, public?: true
    attribute :lock_version, :integer, default: 0, allow_nil?: false
    attribute :is_active, :boolean, default: true

    attribute :last_accessed_at, :utc_datetime_usec do
      allow_nil? true
      public? false
    end

    attribute :scope, :atom do
      allow_nil? false
      default :local
      constraints one_of: [:user, :local, :agent]
      public? true

      description "Memory scope: :user (user-level), :local (conversation-level), or :agent (custom-agent-level)"
    end

    attribute :confidence, :float do
      default 1.0
      allow_nil? false
      public? true
      constraints min: 0.0, max: 1.0
    end

    attribute :kind, :atom do
      constraints one_of: [
                    :general,
                    :fact,
                    :hypothesis,
                    :observation,
                    :summary,
                    :preference,
                    :goal,
                    :topic,
                    :habit,
                    :reflection
                  ]

      default :general
      allow_nil? false
      public? true
    end

    attribute :structured_data, :map do
      allow_nil? true
      public? true
      description "Unvalidated JSON for kind-specific fields (deadlines, streaks, sources, etc.)"
    end

    create_timestamp :inserted_at

    update_timestamp :updated_at do
      public? true
    end
  end

  relationships do
    belongs_to :conversation, Magus.Chat.Conversation, allow_nil?: true
    belongs_to :user, Magus.Accounts.User, allow_nil?: false
    belongs_to :custom_agent, Magus.Agents.CustomAgent, allow_nil?: true

    belongs_to :workspace, Magus.Workspaces.Workspace do
      public? true
      allow_nil? true
    end

    has_many :versions, Magus.Memory.MemoryVersion
    has_many :sources, Magus.Memory.MemorySource

    has_many :associations_as_a, Magus.Memory.MemoryAssociation do
      destination_attribute :memory_a_id
    end

    has_many :associations_as_b, Magus.Memory.MemoryAssociation do
      destination_attribute :memory_b_id
    end
  end

  calculations do
    calculate :vector_distance, :float do
      argument :query_embedding, {:array, :float}, allow_nil?: false

      # L2 distance using pgvector <-> operator for semantic search
      # The query embedding (float array) needs to be cast to vector
      calculation expr(fragment("(summary_embedding <-> ?::vector)", ^arg(:query_embedding)))
    end
  end

  identities do
    identity :unique_name_per_conversation, [:conversation_id, :name],
      where: expr(is_active == true and scope == :local)

    identity :unique_user_name_per_user, [:user_id, :workspace_id, :name],
      where: expr(is_active == true and scope == :user),
      nils_distinct?: false

    identity :unique_name_per_agent, [:custom_agent_id, :name],
      where: expr(is_active == true and scope == :agent)
  end
end
