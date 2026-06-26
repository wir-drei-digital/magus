defmodule Magus.Chat.Message do
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Chat,
    extensions: [AshOban, AshTypescript.Resource],
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  oban do
    triggers do
      trigger :cleanup_stale_streaming do
        action :cleanup_stale_streaming
        queue :maintenance
        scheduler_cron "0 * * * *"
        max_attempts 1
        read_action :read
        worker_module_name Magus.Chat.Message.Workers.CleanupStaleStreaming
        scheduler_module_name Magus.Chat.Message.Schedulers.CleanupStaleStreaming
        where expr(status == :streaming and updated_at < ago(10, :minute))
      end
    end
  end

  typescript do
    type_name "Message"
  end

  postgres do
    table "messages"
    repo Magus.Repo

    custom_indexes do
      # The conversation nav loads (and sorts by) the last_message_at
      # aggregate — max(inserted_at) per conversation. Without the composite
      # index each max scans every message row of the conversation.
      index [:conversation_id, :inserted_at]
    end
  end

  actions do
    defaults update: []

    destroy :destroy do
      primary? true
      require_atomic? false
      change Magus.Chat.Message.Changes.DeleteAttachments
    end

    read :read do
      primary? true
      pagination keyset?: true, required?: false
    end

    read :for_conversation do
      pagination keyset?: true, required?: false
      argument :conversation_id, :uuid, allow_nil?: false

      prepare build(default_sort: [inserted_at: :desc])
      filter expr(conversation_id == ^arg(:conversation_id))
    end

    read :for_llm_context do
      description "Loads messages for LLM context building, excluding disabled messages. When recent_limit is set, returns only the N most recent messages (sorted ascending)."
      pagination keyset?: true, required?: false
      argument :conversation_id, :uuid, allow_nil?: false
      argument :exclude_id, :uuid

      argument :cutoff_at, :utc_datetime_usec do
        allow_nil? true
        description "When set, only include messages with inserted_at <= this timestamp"
      end

      argument :since_at, :utc_datetime_usec do
        allow_nil? true
        description "When set, only include messages with inserted_at >= this timestamp"
      end

      argument :recent_limit, :integer do
        allow_nil? true

        description "When set, fetch only the N most recent messages (sorted desc, reversed by caller)"
      end

      prepare build(sort: [inserted_at: :asc])

      # Load regular chat messages with text content only.
      # Tool events and tool-only assistant turns are excluded — the assistant's
      # final text response already captures tool results. For incomplete turns
      # (error/cancellation), BuildLLMContext handles recovery separately.
      filter expr(
               conversation_id == ^arg(:conversation_id) and disabled != true and
                 message_type == :message and text != "" and not is_nil(text)
             )

      prepare Magus.Chat.Message.Preparations.ForLlmContext
    end

    read :fulltext_search do
      description "Full-text search across messages using PostgreSQL tsvector + pg_trgm"
      argument :query, :string, allow_nil?: false
      pagination offset?: true, default_limit: 20, countable: false

      prepare fn query, context ->
        require Ash.Query

        search_term = Ash.Query.get_argument(query, :query)
        actor = context.actor

        # For fulltext search, we use a subquery to check conversation access
        # to avoid ambiguous column references when joining with conversations table
        # (both messages and conversations have a search_vector column).
        # Security: Users can only search messages in conversations they own or are members of.
        base_query =
          case actor do
            # AI agent can search all messages (used by tools)
            %Magus.Agents.Support.AiAgent{} ->
              query

            %{id: user_id} ->
              query
              |> Ash.Query.filter(
                fragment(
                  """
                  conversation_id IN (
                    SELECT c.id FROM conversations c
                    WHERE c.user_id = ?::uuid
                    UNION
                    SELECT cm.conversation_id FROM conversation_members cm
                    WHERE cm.user_id = ?::uuid AND cm.accepted_at IS NOT NULL
                  )
                  """,
                  type(^user_id, :string),
                  type(^user_id, :string)
                )
              )

            _ ->
              # No actor means return nothing
              query |> Ash.Query.filter(false)
          end

        base_query
        |> Ash.Query.filter(
          fragment(
            "search_vector @@ plainto_tsquery('simple', ?) OR similarity(text, ?) > 0.3",
            ^search_term,
            ^search_term
          )
        )
      end
    end

    read :since do
      description "Get messages for a conversation since a given timestamp"
      argument :conversation_id, :uuid, allow_nil?: false
      argument :since, :utc_datetime_usec, allow_nil?: false

      prepare build(sort: [inserted_at: :asc])

      # Inclusive (>=) so a message sharing the cursor's exact microsecond is
      # never skipped during reconnect gap-fill; clients dedupe by id.
      filter expr(
               conversation_id == ^arg(:conversation_id) and
                 inserted_at >= ^arg(:since) and
                 message_type == :message and
                 disabled != true
             )
    end

    read :search_in_conversation do
      description "Full-text search within a specific conversation"
      argument :conversation_id, :uuid, allow_nil?: false
      argument :query, :string, allow_nil?: false
      pagination offset?: true, default_limit: 10, countable: false

      prepare fn query, context ->
        require Ash.Query

        search_term = Ash.Query.get_argument(query, :query)
        conversation_id = Ash.Query.get_argument(query, :conversation_id)
        actor = context.actor

        # Use subquery to avoid ambiguous column reference (search_vector exists in both
        # messages and conversations tables)
        base_query =
          case actor do
            # AI agent can search any conversation (used by tools)
            %Magus.Agents.Support.AiAgent{} ->
              query
              |> Ash.Query.filter(conversation_id == ^conversation_id)

            %{id: user_id} ->
              query
              |> Ash.Query.filter(
                fragment(
                  """
                  conversation_id = ?::uuid AND conversation_id IN (
                    SELECT c.id FROM conversations c
                    WHERE c.user_id = ?::uuid
                    UNION
                    SELECT cm.conversation_id FROM conversation_members cm
                    WHERE cm.user_id = ?::uuid AND cm.accepted_at IS NOT NULL
                  )
                  """,
                  type(^conversation_id, :string),
                  type(^user_id, :string),
                  type(^user_id, :string)
                )
              )

            _ ->
              query |> Ash.Query.filter(false)
          end

        base_query
        |> Ash.Query.filter(
          fragment(
            "search_vector @@ plainto_tsquery('simple', ?) OR similarity(text, ?) > 0.3",
            ^search_term,
            ^search_term
          )
        )
        |> Ash.Query.sort(inserted_at: :desc)
      end
    end

    create :create do
      accept [:text, :mode, :selected_model_id, :metadata]
      argument :conversation_id, :uuid
      argument :folder_id, :uuid

      change Magus.Chat.Message.Changes.CreateConversationIfNotProvided
      change set_attribute(:role, :user)
      change relate_actor(:created_by)
    end

    create :send_user_message do
      description "Send a user message with full context processing and attached resources"
      accept [:text, :mode, :selected_model_id, :metadata]
      argument :conversation_id, :uuid
      argument :folder_id, :uuid
      argument :custom_agent_id, :uuid
      argument :system_prompt_id, :uuid
      argument :workspace_id, :uuid
      argument :resources, {:array, :map}, default: []

      change Magus.Chat.Message.Changes.AttachResources
      change Magus.Chat.Message.Changes.CreateConversationIfNotProvided
      change set_attribute(:role, :user)
      change relate_actor(:created_by)

      # Signal the conversation agent to process the message
      change Magus.Chat.Message.Changes.SignalAgent
    end

    create :enqueue_message do
      description "Queue a user message for later delivery (no agent dispatch)."
      accept [:text, :mode, :selected_model_id, :metadata]
      argument :conversation_id, :uuid
      argument :folder_id, :uuid
      argument :custom_agent_id, :uuid
      argument :workspace_id, :uuid
      argument :resources, {:array, :map}, default: []

      change Magus.Chat.Message.Changes.AttachResources
      change Magus.Chat.Message.Changes.CreateConversationIfNotProvided
      change set_attribute(:role, :user)
      change set_attribute(:status, :queued)
      change relate_actor(:created_by)
      # NOTE: deliberately no SignalAgent change. Queued messages do not dispatch.
    end

    update :flush_queued do
      description "Promote a queued message to :complete (deliver it)."
      require_atomic? false

      validate attribute_equals(:status, :queued) do
        message "message is not queued"
      end

      change set_attribute(:status, :complete)
      # Order by *delivery* time, not enqueue time: a message queued mid-turn has
      # an earlier `inserted_at` than the agent reply that was streaming when the
      # user typed it, so without this it sorts above that reply.
      change Magus.Chat.Message.Changes.StampDeliveredAt
    end

    destroy :remove_queued do
      description "Remove a queued message before it is delivered."

      validate attribute_equals(:status, :queued) do
        message "message is not queued"
      end
    end

    read :queued_for_conversation do
      argument :conversation_id, :uuid, allow_nil?: false

      filter expr(
               conversation_id == ^arg(:conversation_id) and role == :user and status == :queued
             )

      prepare build(sort: [inserted_at: :asc])
    end

    create :upsert_response do
      upsert? true
      upsert_identity :id

      accept [
        :id,
        :response_to_id,
        :conversation_id,
        :input_tokens,
        :output_tokens,
        :model_name,
        :citations,
        :reasoning_summary,
        :reasoning_details,
        :mode,
        :attachments,
        :tool_call_data,
        :responding_agent_id,
        :metadata
      ]

      argument :id, :uuid, allow_nil?: false
      argument :complete, :boolean, default: false
      argument :text, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true]

      # Set text from argument - works for both create and upsert (update)
      change set_attribute(:text, arg(:text))
      change set_attribute(:complete, arg(:complete))
      change set_attribute(:source, :agent)
      change set_attribute(:role, :agent)
      change set_attribute(:id, arg(:id))

      # on update, update text and complete fields
      upsert_fields [
        :text,
        :complete,
        :input_tokens,
        :output_tokens,
        :model_name,
        :citations,
        :reasoning_summary,
        :reasoning_details,
        :attachments,
        :tool_call_data,
        :metadata
      ]
    end

    create :create_event do
      accept [:text, :conversation_id, :metadata]

      change set_attribute(:message_type, :event)
      change set_attribute(:source, :agent)
      change set_attribute(:role, :agent)
      change set_attribute(:complete, true)
    end

    update :update_event_message do
      description "Update text and/or metadata on an existing :event message (used by HeartbeatEventMessage and similar helpers)."
      accept [:text, :metadata]
      require_atomic? false
    end

    update :cleanup_stale_streaming do
      change set_attribute(:status, :error)
      change set_attribute(:complete, true)

      # Record WHY the row was failed so a swept turn is self-explanatory in the
      # DB instead of an unexplained :error. The row's `updated_at` carries when.
      change set_attribute(:error, %{
               "reason" => "stale_streaming_timeout",
               "detail" =>
                 "Message left in :streaming past the grace period and swept by the cleanup_stale_streaming cron."
             })
    end

    create :create_job_trigger do
      description "Create a job trigger message that initiates an AI agent response"
      accept [:text, :conversation_id, :metadata]

      argument :job_id, :uuid, allow_nil?: false
      argument :job_name, :string, allow_nil?: false
      argument :memory_name, :string

      change set_attribute(:message_type, :job_trigger)
      change set_attribute(:source, :agent)
      change set_attribute(:role, :user)
      change set_attribute(:complete, true)

      # Merge job info into metadata
      change fn changeset, _context ->
        job_id = Ash.Changeset.get_argument(changeset, :job_id)
        job_name = Ash.Changeset.get_argument(changeset, :job_name)
        memory_name = Ash.Changeset.get_argument(changeset, :memory_name)

        existing_metadata = Ash.Changeset.get_attribute(changeset, :metadata) || %{}

        job_metadata =
          Map.merge(existing_metadata, %{
            "job_id" => job_id,
            "job_name" => job_name,
            "memory_name" => memory_name
          })

        Ash.Changeset.force_change_attribute(changeset, :metadata, job_metadata)
      end

      # Signal the conversation agent to process this job trigger
      change Magus.Chat.Message.Changes.SignalAgent
    end

    create :create_draft_event do
      description "Create a draft event message that triggers an AI agent response for draft review/export"
      accept [:text, :conversation_id, :metadata]

      argument :draft_action, :atom, allow_nil?: false, constraints: [one_of: [:review, :export]]
      argument :draft_id, :uuid, allow_nil?: false
      argument :export_format, :atom, constraints: [one_of: [:pdf, :docx, :latex]]

      change set_attribute(:message_type, :draft_event)
      change set_attribute(:source, :agent)
      change set_attribute(:role, :user)
      change set_attribute(:complete, true)
      change relate_actor(:created_by)

      change fn changeset, _context ->
        draft_action = Ash.Changeset.get_argument(changeset, :draft_action)
        draft_id = Ash.Changeset.get_argument(changeset, :draft_id)
        export_format = Ash.Changeset.get_argument(changeset, :export_format)

        existing_metadata = Ash.Changeset.get_attribute(changeset, :metadata) || %{}

        draft_metadata =
          Map.merge(existing_metadata, %{
            "draft_action" => to_string(draft_action),
            "draft_id" => draft_id,
            "export_format" => if(export_format, do: to_string(export_format))
          })

        Ash.Changeset.force_change_attribute(changeset, :metadata, draft_metadata)
      end

      change Magus.Chat.Message.Changes.SignalAgent
    end

    create :upsert_event do
      description "Create or update an event message for tool calls with structured data"
      upsert? true
      upsert_identity :id

      accept [:text, :conversation_id, :tool_call_data]
      argument :id, :uuid, allow_nil?: false
      argument :complete, :boolean, default: true

      change set_attribute(:id, arg(:id))
      change set_attribute(:message_type, :event)
      change set_attribute(:source, :agent)
      change set_attribute(:role, :agent)
      change set_attribute(:complete, arg(:complete))

      upsert_fields [:text, :tool_call_data, :complete]
    end

    update :toggle_disabled do
      accept []
      require_atomic? false

      change fn changeset, _ ->
        current = Ash.Changeset.get_attribute(changeset, :disabled) || false
        Ash.Changeset.change_attribute(changeset, :disabled, !current)
      end
    end

    update :mark_stopped do
      accept []
      require_atomic? false

      change set_attribute(:complete, true)
      change set_attribute(:status, :complete)
    end

    update :mark_error do
      # Optional `error` reason map so defensive cleanups (Recovery,
      # PersistencePlugin on ai.request.failed) leave a trace of WHY a streaming
      # row was failed. Existing callers pass `%{}` and stay backward compatible.
      accept [:error]
      require_atomic? false

      change set_attribute(:complete, true)
      change set_attribute(:status, :error)
    end
  end

  policies do
    # AI Agent can create/update messages (for responses, events, etc.)
    bypass Magus.Checks.IsAiAgent do
      authorize_if always()
    end

    # Fulltext search handles its own authorization in the prepare to avoid
    # column ambiguity issues when joining with conversations table
    bypass action(:fulltext_search) do
      authorize_if always()
    end

    bypass action(:search_in_conversation) do
      authorize_if always()
    end

    # Users can read messages in conversations they own or are members of
    policy action_type(:read) do
      authorize_if expr(conversation.user_id == ^actor(:id))

      authorize_if expr(
                     exists(
                       conversation.members,
                       user_id == ^actor(:id) and not is_nil(accepted_at)
                     )
                   )

      authorize_if Magus.Chat.Message.Checks.WorkspaceConversationAccess
    end

    # Users can create messages in conversations they own or are members of
    # Uses custom check because relationship filters can't be used on create actions
    policy action_type(:create) do
      authorize_if Magus.Chat.Message.Checks.CanCreateInConversation
    end

    # Users can update messages in conversations they own or are members of
    policy action_type(:update) do
      authorize_if expr(conversation.user_id == ^actor(:id))

      authorize_if expr(
                     exists(
                       conversation.members,
                       user_id == ^actor(:id) and not is_nil(accepted_at)
                     )
                   )
    end

    # Users can delete messages in conversations they own
    policy action_type(:destroy) do
      authorize_if expr(conversation.user_id == ^actor(:id))
    end
  end

  pub_sub do
    module MagusWeb.Endpoint
    prefix "chat"

    # `:create` and `:send_user_message` share the same payload shape so peers
    # receive enough fields to render the bubble (timestamp, indicators,
    # attachments) regardless of which create path was used.
    publish :create, ["messages", :conversation_id] do
      transform fn %{data: message} ->
        %{
          text: message.text,
          id: message.id,
          source: message.source,
          complete: message.complete,
          created_by_id: message.created_by_id,
          message_type: message.message_type,
          inserted_at: message.inserted_at,
          metadata: message.metadata,
          attachments: message.attachments
        }
      end
    end

    publish :send_user_message, ["messages", :conversation_id] do
      transform fn %{data: message} ->
        %{
          text: message.text,
          id: message.id,
          source: message.source,
          complete: message.complete,
          created_by_id: message.created_by_id,
          message_type: message.message_type,
          inserted_at: message.inserted_at,
          metadata: message.metadata,
          attachments: message.attachments
        }
      end
    end

    publish :enqueue_message, ["queued", :conversation_id] do
      transform fn %{data: message} ->
        %{
          text: message.text,
          id: message.id,
          status: message.status,
          source: message.source,
          created_by_id: message.created_by_id,
          message_type: message.message_type,
          inserted_at: message.inserted_at,
          metadata: message.metadata,
          attachments: message.attachments
        }
      end
    end

    # On flush, render the bubble in the main thread (chat:messages) AND tell the
    # queue UI to drop it (chat:queued).
    publish :flush_queued, ["messages", :conversation_id] do
      transform fn %{data: message} ->
        %{
          text: message.text,
          id: message.id,
          source: message.source,
          complete: message.complete,
          created_by_id: message.created_by_id,
          message_type: message.message_type,
          inserted_at: message.inserted_at,
          metadata: message.metadata,
          attachments: message.attachments
        }
      end
    end

    publish :flush_queued, ["queued", :conversation_id] do
      transform fn %{data: message} ->
        %{id: message.id, status: message.status}
      end
    end

    publish :remove_queued, ["queued", :conversation_id] do
      transform fn %{data: message} -> %{id: message.id} end
    end

    publish :upsert_response, ["messages", :conversation_id] do
      transform fn %{data: message} ->
        %{
          text: message.text,
          id: message.id,
          source: message.source,
          complete: message.complete,
          created_by_id: message.created_by_id,
          model_name: message.model_name,
          citations: message.citations,
          reasoning_summary: message.reasoning_summary,
          mode: message.mode,
          attachments: message.attachments,
          message_type: message.message_type,
          inserted_at: message.inserted_at,
          responding_agent_id: message.responding_agent_id,
          metadata: message.metadata
        }
      end
    end

    # Deletes broadcast on their own topic: classic stream-inserts ANY
    # payload arriving on chat:messages:* (frozen behavior), so an id-only
    # delete there would render a phantom row. Only the SPA channel
    # subscribes to this one.
    publish :destroy, ["message_deletes", :conversation_id] do
      transform fn %{data: message} ->
        %{id: message.id}
      end
    end

    publish :create_event, ["messages", :conversation_id] do
      transform fn %{data: message} ->
        %{
          text: message.text,
          id: message.id,
          source: message.source,
          complete: message.complete,
          message_type: message.message_type,
          metadata: message.metadata,
          inserted_at: message.inserted_at
        }
      end
    end

    publish :create_job_trigger, ["messages", :conversation_id] do
      transform fn %{data: message} ->
        %{
          text: message.text,
          id: message.id,
          source: message.source,
          complete: message.complete,
          message_type: message.message_type,
          metadata: message.metadata,
          inserted_at: message.inserted_at
        }
      end
    end

    publish :create_draft_event, ["messages", :conversation_id] do
      transform fn %{data: message} ->
        %{
          text: message.text,
          id: message.id,
          source: message.source,
          complete: message.complete,
          message_type: message.message_type,
          metadata: message.metadata,
          inserted_at: message.inserted_at
        }
      end
    end

    publish :upsert_event, ["messages", :conversation_id] do
      transform fn %{data: message} ->
        %{
          text: message.text,
          id: message.id,
          source: message.source,
          complete: message.complete,
          message_type: message.message_type,
          tool_call_data: message.tool_call_data,
          inserted_at: message.inserted_at
        }
      end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom do
      allow_nil? false
      constraints one_of: [:system, :user, :agent, :tool]
      public? true
    end

    attribute :model, :string do
      allow_nil? true
      public? true
      description "Model used for assistant messages"
    end

    # Token tracking per message
    attribute :input_tokens, :integer do
      allow_nil? true
    end

    attribute :output_tokens, :integer do
      allow_nil? true
    end

    # Memory.Resource IDs for files attached to this message
    attribute :attachments, {:array, :uuid} do
      allow_nil? false
      default []
      public? true

      description "Memory.Resource IDs attached to this message (user uploads and agent-generated)"
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
      description "Message metadata including user-uploaded attachments"
    end

    attribute :status, :atom do
      allow_nil? false
      default :complete
      constraints one_of: [:pending, :streaming, :complete, :error, :queued]
      public? true
    end

    attribute :error, :map do
      allow_nil? true
      description "Error details if status is :error"
    end

    # Public so API clients can order messages and derive gap-fill cursors.
    timestamps public?: true

    attribute :text, :string do
      constraints allow_empty?: true, trim?: false
      public? true
      allow_nil? false
    end

    attribute :tool_results, {:array, :map}

    attribute :source, Magus.Chat.Message.Types.Source do
      allow_nil? false
      public? true
      default :user
    end

    attribute :complete, :boolean do
      allow_nil? false
      default true
    end

    attribute :mode, :atom do
      allow_nil? false
      default :chat
      constraints one_of: [:chat, :search, :reasoning, :image_generation, :video_generation]
      public? true
      description "Chat mode used for this message"
    end

    attribute :message_type, :atom do
      allow_nil? false
      default :message
      constraints one_of: [:message, :event, :job_trigger, :draft_event]
      public? true

      description "Type of message: :message for regular chat, :event for tool calls/system events, :job_trigger for scheduled job executions, :draft_event for draft review/export triggers"
    end

    attribute :model_name, :string do
      allow_nil? true
      public? true
      description "Display name of model that generated this response"
    end

    attribute :citations, {:array, :map} do
      allow_nil? false
      default []
      public? true
      description "Web search citations [{url, title, start_index, end_index}]"
    end

    attribute :reasoning_summary, {:array, :string} do
      allow_nil? false
      default []
      public? true
      description "Reasoning steps from reasoning mode (display only)"
    end

    attribute :reasoning_details, {:array, :map} do
      allow_nil? false
      default []
      public? true

      description "Full reasoning blocks for API preservation [{type, summary, text, format, index}]"
    end

    attribute :disabled, :boolean do
      allow_nil? false
      default false
      public? true
      description "If true, message is excluded from AI context"
    end

    attribute :tool_call_data, :map do
      allow_nil? true
      public? true

      description "Structured tool call data: {id, tool_name, display_name, inputs, output, output_summary, status, error, started_at, completed_at, duration_ms}"
    end
  end

  relationships do
    belongs_to :created_by, Magus.Accounts.User do
      allow_nil? true
    end

    belongs_to :conversation, Magus.Chat.Conversation do
      public? true
      allow_nil? false
    end

    belongs_to :response_to, __MODULE__ do
      public? true
    end

    has_one :response, __MODULE__ do
      public? true
      destination_attribute :response_to_id
    end

    belongs_to :responding_agent, Magus.Agents.CustomAgent do
      allow_nil? true
      public? true
      attribute_writable? true
      description "The custom agent that generated this response (for @mention attribution)"
    end

    belongs_to :selected_model, Magus.Chat.Model do
      public? true
      allow_nil? true
      description "Model selected for this message's response"
    end

    has_many :threads, Magus.Chat.Conversation do
      public? true
      destination_attribute :branched_at_message_id
    end
  end

  calculations do
    calculate :needs_response, :boolean do
      # User messages, job triggers, and draft events need responses (if they don't already have one)
      calculation expr(
                    (source == :user or message_type in [:job_trigger, :draft_event]) and
                      not exists(response)
                  )
    end

    calculate :as_llm_message, :map do
      argument :is_multiplayer, :boolean, default: false
      argument :include_tool_calls, :boolean, default: false
      calculation Magus.Chat.Message.Calculations.AsLlmMessage
    end
  end

  aggregates do
    count :thread_count, :threads do
      public? true
      filter expr(is_nil(deleted_at))
    end

    count :thread_message_count, [:threads, :messages] do
      public? true
    end
  end

  identities do
    identity :id, [:id]
  end
end
