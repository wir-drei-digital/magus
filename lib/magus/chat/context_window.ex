defmodule Magus.Chat.ContextWindow do
  @moduledoc """
  Per-conversation context-window state: the live token snapshot, the window
  pointer (floor), an optional compaction summary, the per-conversation strategy
  override, and the compaction state machine. One row per conversation.

  ## Authorization

  - The AI agent actor (`Magus.Checks.IsAiAgent`) bypasses all policies: the
    system agent reads and writes this row freely (ContextPlugin snapshot/usage
    writes, message-history assembly reads).
  - `get_or_create` is an upsert that returns the existing row for any
    `conversation_id`, so it is owner-gated (`ConversationOwner` check, which
    resolves the conversation by the accepted `conversation_id` since the
    relationship does not exist yet at create time). System callers are covered
    by the bypasses above.
  - The remaining internal write actions `upsert_snapshot`, `patch_usage`, and
    the compaction mechanism actions `mark_compacting`, `compact`,
    `mark_failed`, and `run_compaction` allow anyone (`always()`): they are
    never exposed to a user actor and are run by internal/test paths or the Oban
    compaction trigger (which also carries the `AshObanInteraction` bypass for
    its scheduler/worker reads).
  - The user-facing `set_strategy`, `clear`, and `request_compaction` actions
    require the conversation owner (`conversation.user_id == actor(:id)`).
    `request_compaction` is also reachable by the auto-compact valve, which
    runs as the AI agent (covered by the bypass).
  - Reads require the conversation owner, an accepted multiplayer member, a
    workspace grantee, or an admin (`Magus.Checks.IsAdmin`); the AI agent is
    already covered by the bypass above. This mirrors `Magus.Chat.Message`'s
    read policy so anyone who can read the conversation also sees the read-only
    context donut. Mutating actions stay owner-only, so members can view but
    not change the window.
  """
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Chat,
    extensions: [AshOban, AshTypescript.Resource],
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  oban do
    triggers do
      # Compact a window once it is marked :pending. The work is enqueued
      # on-demand (see :request_compaction's after_action calling
      # AshOban.run_trigger/2) so the Send path is never blocked waiting on a
      # slow cron. The */1 cron is a safety net for any :pending row that did
      # not get an on-demand enqueue (e.g. a crashed insert): re-running
      # :run_compaction settles it to :idle/:failed so the composer is never
      # locked forever. :pending is the only in-flight state the trigger path
      # produces (it runs :run_compaction directly with no claim-to-:running
      # step), so that is the only state the cron needs to reclaim.
      trigger :compact_context do
        action :run_compaction
        queue :context_compaction
        scheduler_cron "*/1 * * * *"
        worker_module_name Magus.Chat.ContextWindow.Workers.CompactContext
        scheduler_module_name Magus.Chat.ContextWindow.Schedulers.CompactContext

        where expr(compaction_status == :pending)
      end
    end
  end

  typescript do
    type_name "context_window"
  end

  postgres do
    table "context_windows"
    repo Magus.Repo

    references do
      reference :conversation, on_delete: :delete
      reference :window_start_message, on_delete: :nilify
    end
  end

  actions do
    defaults [:read]

    read :get_for_conversation do
      argument :conversation_id, :uuid, allow_nil?: false
      get? true
      filter expr(conversation_id == ^arg(:conversation_id))
    end

    create :get_or_create do
      upsert? true
      upsert_identity :unique_conversation
      accept [:conversation_id]
      upsert_fields []
    end

    create :upsert_snapshot do
      upsert? true
      upsert_identity :unique_conversation

      accept [
        :conversation_id,
        :last_breakdown,
        :last_total_tokens,
        :last_actual_input_tokens,
        :last_cached_tokens,
        :last_model_key,
        :last_max_context
      ]

      upsert_fields [
        :last_breakdown,
        :last_total_tokens,
        :last_actual_input_tokens,
        :last_cached_tokens,
        :last_model_key,
        :last_max_context
      ]
    end

    update :patch_usage do
      accept [:last_actual_input_tokens, :last_cached_tokens]
    end

    update :set_strategy do
      accept [:strategy]
    end

    update :clear do
      description "Instant pointer reset: advance the window floor and drop the summary."
      accept [:window_start_message_id, :window_start_at]
      change set_attribute(:summary, nil)
      change set_attribute(:summary_message_count, 0)
    end

    update :request_compaction do
      description "Enqueue this window for compaction (owner UI or auto-compact valve)."
      require_atomic? false
      change set_attribute(:compaction_status, :pending)

      # On-demand enqueue: kick the :compact_context Oban trigger for this row so
      # the Send path is not blocked waiting on the */1 cron. Best-effort: a
      # raise here would roll back the :pending transition and crash the caller,
      # so swallow it and let the */1 cron safety net pick the row up instead.
      change after_action(fn _changeset, record, _context ->
               try do
                 AshOban.run_trigger(record, :compact_context)
               rescue
                 e ->
                   require Logger

                   Logger.warning(
                     "request_compaction on-demand enqueue failed (cron fallback will retry): #{Exception.message(e)}"
                   )
               end

               {:ok, record}
             end)
    end

    update :mark_compacting do
      description "Oban trigger claims a :pending row: transition to :running."
      change set_attribute(:compaction_status, :running)
    end

    update :run_compaction do
      description "Oban trigger work action: summarize older messages, advance the window floor, return to :idle (or :failed on error)."
      transaction? false
      require_atomic? false
      change Magus.Chat.ContextWindow.Changes.RunCompaction
    end

    update :compact do
      description "Store the summary, advance the window floor, and return to :idle."
      accept [:summary, :summary_message_count, :window_start_message_id, :window_start_at]
      change set_attribute(:compaction_status, :idle)
    end

    update :mark_failed do
      description "Oban trigger could not compact: transition to :failed."
      change set_attribute(:compaction_status, :failed)
    end

    # ------------------------------------------------------------------------
    # Conversation-keyed generic actions (shared by the LiveView donut controls
    # and the SPA RPC surface). Each get-or-creates the row, performs the op,
    # broadcasts `context.updated`, and returns the updated row. The work is
    # delegated to Magus.Chat.ContextWindow.Operations, which threads the actor
    # through every underlying call (so the get_or_create + op policies enforce
    # ownership). The generic-action policies below add ownership as a
    # first-line gate (resolving the conversation by the `conversation_id`
    # argument).
    # ------------------------------------------------------------------------

    action :clear_for_conversation, :struct do
      constraints instance_of: __MODULE__
      description "Clear the window to just past the latest message (owner UI / SPA)."
      argument :conversation_id, :uuid, allow_nil?: false

      run fn input, context ->
        Magus.Chat.ContextWindow.Operations.clear(
          input.arguments.conversation_id,
          Ash.Context.to_opts(context)
        )
      end
    end

    action :compact_for_conversation, :struct do
      constraints instance_of: __MODULE__
      description "Request a compaction pass for the conversation (owner UI / SPA)."
      argument :conversation_id, :uuid, allow_nil?: false

      run fn input, context ->
        Magus.Chat.ContextWindow.Operations.compact(
          input.arguments.conversation_id,
          Ash.Context.to_opts(context)
        )
      end
    end

    action :set_strategy_for_conversation, :struct do
      constraints instance_of: __MODULE__
      description "Set the per-conversation strategy override (owner UI / SPA)."
      argument :conversation_id, :uuid, allow_nil?: false

      argument :strategy, :atom do
        allow_nil? true
        constraints one_of: [:rolling, :compact]
      end

      run fn input, context ->
        Magus.Chat.ContextWindow.Operations.set_strategy(
          input.arguments.conversation_id,
          input.arguments.strategy,
          Ash.Context.to_opts(context)
        )
      end
    end
  end

  policies do
    # The :compact_context Oban trigger reads (:read scheduler/worker read) and
    # writes (:run_compaction) this row without a user actor. Let the AshOban
    # interaction through completely.
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # The system agent reads and writes the snapshot freely (ContextPlugin
    # writes, message-history assembly reads).
    bypass Magus.Checks.IsAiAgent do
      authorize_if always()
    end

    # get_or_create is an upsert that returns the EXISTING row for any
    # conversation_id, so an always() policy would let a non-owner read another
    # user's window/summary via an arbitrary id. Gate it on conversation
    # ownership. The relationship does not exist yet at create time, so the
    # custom check resolves the conversation by the accepted conversation_id
    # (the IsAiAgent / AshObanInteraction bypasses still cover system callers).
    policy action(:get_or_create) do
      authorize_if Magus.Chat.ContextWindow.Checks.ConversationOwner
    end

    # Internal-only write actions: never exposed to a user actor, and called
    # without an actor from internal/test paths. The compaction mechanism
    # actions (mark_compacting/compact/mark_failed) are run by the Oban trigger;
    # always() keeps them robust regardless of the trigger's actor.
    policy action([
             :upsert_snapshot,
             :patch_usage,
             :mark_compacting,
             :compact,
             :mark_failed,
             :run_compaction
           ]) do
      authorize_if always()
    end

    # User-facing strategy toggle + pointer reset: conversation owner only.
    policy action([:set_strategy, :clear]) do
      authorize_if expr(conversation.user_id == ^actor(:id))
    end

    # Compaction request: owner (UI) or the auto-compact valve (AiAgent actor,
    # already covered by the bypass above).
    policy action(:request_compaction) do
      authorize_if expr(conversation.user_id == ^actor(:id))
    end

    # Conversation-keyed generic actions (LiveView donut + SPA RPC). Gated on
    # conversation ownership: the check resolves the conversation by the
    # `conversation_id` argument (these actions carry an ActionInput, not a
    # changeset/query). The underlying get_or_create + op calls re-enforce
    # ownership. AI agent / AshOban system callers are covered by the bypasses
    # above.
    policy action([
             :clear_for_conversation,
             :compact_for_conversation,
             :set_strategy_for_conversation
           ]) do
      authorize_if Magus.Chat.ContextWindow.Checks.ConversationOwner
    end

    # Reads: conversation owner, accepted multiplayer members, workspace
    # grantees, or admin (AI agent covered by the bypass). Mirrors
    # Magus.Chat.Message's read policy so a member who can read the conversation
    # also sees the read-only context donut. Mutating actions above stay
    # owner-only, so members can view the window but cannot change it.
    policy action_type(:read) do
      authorize_if expr(conversation.user_id == ^actor(:id))

      authorize_if expr(
                     exists(
                       conversation.members,
                       user_id == ^actor(:id) and not is_nil(accepted_at)
                     )
                   )

      authorize_if Magus.Chat.Message.Checks.WorkspaceConversationAccess

      authorize_if Magus.Checks.IsAdmin
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :strategy, :atom do
      allow_nil? true
      public? true
      constraints one_of: [:rolling, :compact]
      description "Per-conversation override; nil inherits user/config."
    end

    # Donut-relevant fields are public for typescript field selection (SPA reads
    # the breakdown + totals + model + compaction_status). `summary` is public
    # too: the context-floor divider expands to show it in both UIs. Reads stay
    # gated by the owner/member/workspace/admin read policy below.
    attribute :window_start_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :summary, :string, allow_nil?: true, public?: true
    attribute :summary_message_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :last_breakdown, :map, allow_nil?: true, public?: true
    attribute :last_total_tokens, :integer, allow_nil?: true, public?: true
    attribute :last_actual_input_tokens, :integer, allow_nil?: true, public?: true
    attribute :last_cached_tokens, :integer, allow_nil?: true, public?: true
    attribute :last_model_key, :string, allow_nil?: true, public?: true
    attribute :last_max_context, :integer, allow_nil?: true, public?: true

    attribute :compaction_status, :atom do
      allow_nil? false
      default :idle
      public? true
      constraints one_of: [:idle, :pending, :running, :failed]
    end

    timestamps()
  end

  relationships do
    belongs_to :conversation, Magus.Chat.Conversation do
      allow_nil? false
    end

    belongs_to :window_start_message, Magus.Chat.Message do
      allow_nil? true
    end
  end

  identities do
    identity :unique_conversation, [:conversation_id]
  end

  @config_key Magus.Chat.ContextWindow

  @doc "Read a config default (see config/config.exs)."
  def config(key) do
    :magus |> Application.get_env(@config_key, []) |> Keyword.fetch!(key)
  end

  @doc """
  Resolve the effective strategy: per-conversation override first, then the
  user default, then the app config default. Argument keys: :strategy
  (per-conversation, nilable) and :user_default (per-user, nilable).
  """
  @spec resolve_strategy(%{strategy: atom() | nil, user_default: atom() | nil}) :: atom()
  def resolve_strategy(%{strategy: s, user_default: u}), do: s || u || config(:default_strategy)

  @doc """
  Best-effort per-user default strategy for a conversation: load the
  conversation's `user_id`, then that user's `context_strategy`. Returns the
  atom or `nil` on any miss (no user, deleted conversation, read failure) so
  `resolve_strategy/1` falls back to the config default.

  Reads as the AI agent / `authorize?: false` so it works from system paths
  (message-history assembly, the auto-compact valve).
  """
  @spec user_default_strategy(Ecto.UUID.t()) :: atom() | nil
  def user_default_strategy(conversation_id) do
    require Ash.Query

    with {:ok, %{user_id: user_id}} when not is_nil(user_id) <-
           Magus.Chat.Conversation
           |> Ash.Query.filter(id == ^conversation_id)
           |> Ash.Query.select([:user_id])
           |> Ash.read_one(actor: %Magus.Agents.Support.AiAgent{}),
         {:ok, %{context_strategy: strategy}} <-
           Magus.Accounts.User
           |> Ash.Query.filter(id == ^user_id)
           |> Ash.Query.select([:context_strategy])
           |> Ash.read_one(authorize?: false) do
      strategy
    else
      _ -> nil
    end
  end
end
