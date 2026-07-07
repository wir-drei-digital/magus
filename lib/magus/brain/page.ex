defmodule Magus.Brain.Page do
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Brain,
    extensions: [AshOban, AshPaperTrail.Resource, AshTypescript.Resource],
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    primary_read_warning?: false

  oban do
    triggers do
      trigger :name_page do
        action :generate_name
        queue :brain_name_page
        scheduler_cron "*/5 * * * *"
        read_action :read_for_scheduler
        worker_read_action :read_for_scheduler
        worker_module_name Magus.Brain.Page.Workers.NamePage
        scheduler_module_name Magus.Brain.Page.Schedulers.NamePage
        where expr(needs_title)
      end

      trigger :cleanup_trashed do
        action :destroy
        queue :brain_page_cleanup
        scheduler_cron "@daily"
        read_action :trashed_for_cleanup
        worker_read_action :trashed_for_cleanup
        worker_module_name Magus.Brain.Page.Workers.CleanupTrashed
        scheduler_module_name Magus.Brain.Page.Schedulers.CleanupTrashed
      end
    end
  end

  require Magus.Brain.Page.Filters
  import Magus.Brain.Page.Filters, only: [no_trashed_ancestor: 0]

  paper_trail do
    primary_key_type :uuid_v7
    change_tracking_mode :snapshot
    store_action_name? true
    reference_source? false
    # Phase C: `body` and `frontmatter` are now tracked. Every successful
    # `update_body` creates a Version row capturing the prior snapshot,
    # which `Magus.Agents.Tools.Brain.EditBrain.undo_last_edit` (C3)
    # restores from. `lock_version` and `search_vector` stay ignored:
    # they're derived state, not content.
    ignore_attributes [
      :inserted_at,
      :updated_at,
      :lock_version,
      :search_vector
    ]

    belongs_to_actor :user, Magus.Accounts.User, domain: Magus.Accounts

    # AshPaperTrail dynamically generates `Magus.Brain.Page.Version` from this
    # block. Without policies it's wide open to any caller that knows the
    # module name. Attach the policy authorizer so the resource defaults to
    # forbidding all access; internal callers use `authorize?: false` to
    # bypass. The existing `Magus.Brain.Block.Version` has the same gap but
    # is slated for deletion in Phase D so it's left alone here. Phase C
    # adds explicit read policies once body/frontmatter become tracked and a
    # legitimate read use case exists.
    version_extensions authorizers: [Ash.Policy.Authorizer]
  end

  typescript do
    type_name "BrainPage"
  end

  postgres do
    table "brain_pages"
    repo Magus.Repo

    identity_wheres_to_sql unique_slug_per_brain: "deleted_at IS NULL"

    references do
      reference :brain, on_delete: :delete
      reference :parent_page, on_delete: :delete
      # Deleting a spec page nilifies its plans' links rather than cascading:
      # a plan outlives the spec it implemented.
      reference :spec_page, on_delete: :nilify
    end

    custom_indexes do
      index [:deleted_at], name: "brain_pages_deleted_at_index"
    end
  end

  actions do
    read :read do
      primary? true
      filter expr(is_nil(deleted_at) and ^no_trashed_ancestor())
    end

    read :read_for_scheduler do
      pagination keyset?: true, required?: false
      filter expr(is_nil(deleted_at) and ^no_trashed_ancestor())
    end

    read :read_including_trashed do
      description """
      Internal action. Returns active AND trashed rows. Used internally
      by `ClearDeleted` to walk the ancestor chain checking for trashed
      parents (the default `:read` filter hides them), and by
      `DestroyDescendantsFirst` to walk children regardless of their
      `:deleted_at` state.

      NEVER expose this via the domain interface or a LiveView — its
      bypass policy means it returns every brain page in the database.
      """
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      change Magus.Brain.Page.Changes.DestroyDescendantsFirst
      change {Magus.Brain.Changes.BroadcastBrainEvent, resource_type: :page}
      change {Magus.Chat.Changes.UnlinkCompanions, resource_type: :brain_page}
    end

    create :create do
      primary? true
      accept [:title, :icon, :parent_page_id, :kind]
      argument :brain_id, :uuid, allow_nil?: false
      change set_attribute(:brain_id, arg(:brain_id))
      change set_attribute(:contributor_type, :user)
      change set_attribute(:contributor_id, actor(:id))
      change {Magus.Brain.Changes.Slugify, attribute: :title, target: :slug}

      change {Magus.Brain.Changes.AutoPosition,
              resource: Magus.Brain.Page,
              scope_attribute: :brain_id,
              parent_attribute: :parent_page_id}

      change {Magus.Brain.Changes.BroadcastBrainEvent, resource_type: :page}
      change Magus.Brain.Page.Changes.SetDepthFromParent
    end

    create :create_as_external_agent do
      accept [:title, :icon, :parent_page_id, :kind]
      argument :brain_id, :uuid, allow_nil?: false
      argument :external_agent_id, :uuid, allow_nil?: false

      change set_attribute(:brain_id, arg(:brain_id))
      change Magus.Brain.Changes.SetExternalContributor
      change {Magus.Brain.Changes.Slugify, attribute: :title, target: :slug}

      change {Magus.Brain.Changes.AutoPosition,
              resource: Magus.Brain.Page,
              scope_attribute: :brain_id,
              parent_attribute: :parent_page_id}

      change {Magus.Brain.Changes.BroadcastBrainEvent, resource_type: :page}
      change Magus.Brain.Page.Changes.SetDepthFromParent
    end

    update :update_title do
      accept [:title]
      require_atomic? false
      change {Magus.Brain.Changes.BroadcastBrainEvent, resource_type: :page}
    end

    update :update_body do
      description """
      Phase C: replace the markdown body. The single write path for page
      content. Uses `optimistic_lock(:lock_version)` to detect concurrent
      edits before the DB layer, validates that referenced files live in
      the same workspace, then rebuilds every derived index inline in the
      same transaction (frontmatter cache, page links, sources +
      page_sources, page_tags, and page_chunks).

      Returns a `Magus.Brain.Page.Errors.VersionConflict` (wrapped in
      `Ash.Error.Invalid`) when the supplied `:base_version` argument
      doesn't match the page's current `lock_version`. The error carries
      the current body, version, modified-at timestamp, and the
      `contributor_id` of the conflicting save so the editor can render
      its LWW recovery toast without a second DB round-trip.
      """

      require_atomic? false
      accept [:body]
      argument :base_version, :integer, allow_nil?: false

      # Note: MatchesLockVersion is a `change` (with a before_action +
      # FOR UPDATE re-read) rather than a `validate`, so it can return a
      # structured `VersionConflict` ahead of the data layer's bare
      # `StaleRecord`. See its module doc for the rationale.
      change Magus.Brain.Page.Validations.MatchesLockVersion
      validate Magus.Brain.Page.Validations.FileReferencesInWorkspace
      change optimistic_lock(:lock_version)
      change set_attribute(:contributor_type, :user)
      change set_attribute(:contributor_id, actor(:id))
      change Magus.Brain.Page.Changes.UpdateBodyDerivedState
      change {Magus.Brain.Changes.BroadcastBrainEvent, resource_type: :page}
      change Magus.Brain.Page.Changes.EnqueueSuperBrainExtraction
    end

    update :generate_name do
      accept []
      transaction? false
      require_atomic? false
      change Magus.Brain.Page.Changes.GeneratePageName
    end

    update :reposition do
      accept [:position, :depth]
    end

    update :set_kind do
      description "Promote/demote a page between :page, :plan, and :spec."
      accept [:kind]
      require_atomic? false
      change {Magus.Brain.Changes.BroadcastBrainEvent, resource_type: :page}
    end

    update :set_spec do
      description "Link a :plan page to the :spec page it implements (or clear it with nil)."
      accept [:spec_page_id]
      require_atomic? false
      change {Magus.Brain.Changes.BroadcastBrainEvent, resource_type: :page}
    end

    update :mark_delivered do
      description """
      Explicit delivery gate: stamps :delivered_at now (so :lifecycle becomes
      :delivered) and optionally records a :delivery_ref. The anti-stranding
      counterpart of the auto-derived :done.
      """

      accept [:delivery_ref]
      require_atomic? false
      change set_attribute(:delivered_at, &DateTime.utc_now/0)
      change {Magus.Brain.Changes.BroadcastBrainEvent, resource_type: :page}
    end

    update :undeliver do
      description "Clears the delivery gate, returning the page to its derived lifecycle (:done/:active/:draft)."
      accept []
      require_atomic? false
      change set_attribute(:delivered_at, nil)
      change set_attribute(:delivery_ref, nil)
      change {Magus.Brain.Changes.BroadcastBrainEvent, resource_type: :page}
    end

    update :move_to_parent do
      accept [:parent_page_id]
      require_atomic? false
      change Magus.Brain.Page.Changes.MoveToParent
      change {Magus.Brain.Changes.BroadcastBrainEvent, resource_type: :page}
    end

    update :soft_delete do
      description """
      Moves a page to the trash. Idempotent — calling on an already-
      trashed page is a no-op (preserves the original `:deleted_at`
      timestamp). Sub-pages are NOT cascade-stamped; they become
      invisible to read actions by virtue of having a trashed
      ancestor. Restoring this page restores the whole subtree
      automatically. Permanent destroy hard-deletes the subtree via
      the Postgres FK cascade.
      """

      accept []
      require_atomic? false
      change Magus.Brain.Page.Changes.MarkDeleted
      change {Magus.Brain.Changes.BroadcastBrainEvent, resource_type: :page}
    end

    update :restore do
      description """
      Removes a page from the trash. Refuses to run when an ancestor
      is still trashed (would otherwise leave an orphan visible page
      under a hidden parent).
      """

      accept []
      require_atomic? false
      change Magus.Brain.Page.Changes.ClearDeleted
      change {Magus.Brain.Changes.BroadcastBrainEvent, resource_type: :page}
    end

    read :for_brain do
      argument :brain_id, :uuid, allow_nil?: false

      filter expr(brain_id == ^arg(:brain_id) and is_nil(deleted_at) and ^no_trashed_ancestor())

      prepare build(sort: [position: :asc])
    end

    read :by_title_in_brain do
      argument :brain_id, :uuid, allow_nil?: false
      argument :title, :string, allow_nil?: false

      filter expr(
               brain_id == ^arg(:brain_id) and title == ^arg(:title) and is_nil(deleted_at) and
                 ^no_trashed_ancestor()
             )
    end

    # Case-insensitive variant of :by_title_in_brain. Used by Writer to
    # avoid creating duplicate pages when the agent passes a title with
    # different casing from an existing page ("Brain" vs "brain"). Exact
    # match is still tried first so explicit-case ties resolve naturally.
    read :by_title_in_brain_ci do
      argument :brain_id, :uuid, allow_nil?: false
      argument :title, :string, allow_nil?: false

      filter expr(
               brain_id == ^arg(:brain_id) and
                 fragment("LOWER(?) = LOWER(?)", title, ^arg(:title)) and
                 is_nil(deleted_at) and ^no_trashed_ancestor()
             )
    end

    read :root_pages do
      argument :brain_id, :uuid, allow_nil?: false

      filter expr(brain_id == ^arg(:brain_id) and is_nil(parent_page_id) and is_nil(deleted_at))

      prepare build(sort: [position: :asc])
    end

    read :children_of do
      argument :parent_page_id, :uuid, allow_nil?: false

      filter expr(
               parent_page_id == ^arg(:parent_page_id) and is_nil(deleted_at) and
                 ^no_trashed_ancestor()
             )

      prepare build(sort: [position: :asc])
    end

    read :trashed do
      description """
      Deletion roots in the trash, workspace-scoped via
      `brain.workspace_id`. A "deletion root" is a trashed page whose
      ancestors are NOT also trashed — the row a user would restore
      to bring the whole subtree back.
      """

      argument :workspace_id, :uuid, allow_nil?: true
      pagination keyset?: true, required?: false

      prepare Magus.Brain.Page.Preparations.FilterTrashedRoots
      prepare build(sort: [deleted_at: :desc], load: [:brain])
    end

    read :trashed_for_cleanup do
      description "Pages soft-deleted more than 30 days ago. Used by the daily Oban cleanup trigger."
      pagination keyset?: true, required?: false
      filter expr(not is_nil(deleted_at) and deleted_at < ago(30, :day))
    end

    action :versions, {:array, :map} do
      description """
      Page version history (newest first) for the workbench Activity tab.
      Entries come from `Magus.Brain.PageHistory.list_for_page/2`
      (version_id, inserted_at, action_name, contributor_id, preview).
      Authorization is delegated to `get_page/2` inside the run — the
      versions themselves are read with `authorize?: false` by PageHistory.
      """

      argument :page_id, :uuid, allow_nil?: false

      run fn input, context ->
        page_id = input.arguments.page_id

        with {:ok, _page} <- Magus.Brain.get_page(page_id, actor: context.actor) do
          {:ok, Magus.Brain.list_page_versions(page_id)}
        end
      end
    end

    action :version_diff, :map do
      description """
      Token-level diff of one version against its predecessor for the
      Activity tab viewer. Tuples from `Magus.Brain.Diff` are reshaped into
      JSON-safe maps; authorization is delegated to `get_page/2`.
      """

      argument :page_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      run fn input, context ->
        with {:ok, _page} <- Magus.Brain.get_page(input.arguments.page_id, actor: context.actor),
             {:ok, data} <-
               Magus.Brain.page_version_diff(
                 input.arguments.page_id,
                 input.arguments.version_id
               ) do
          rows =
            Enum.map(data.diff_rows, fn
              %{kind: :gap, count: count} ->
                %{kind: "gap", count: count}

              %{kind: kind, tokens: tokens} ->
                %{
                  kind: to_string(kind),
                  tokens:
                    Enum.map(tokens, fn {token_kind, text} ->
                      %{kind: to_string(token_kind), text: text}
                    end)
                }
            end)

          {:ok,
           %{
             version_id: data.version_id,
             inserted_at: data.inserted_at,
             action_name: data.action_name,
             is_latest: data.is_latest?,
             rows: rows
           }}
        else
          :error -> {:error, Ash.Error.Query.NotFound.exception(resource: __MODULE__)}
          {:error, _} = error -> error
        end
      end
    end

    action :version_body, :string do
      description """
      Full markdown snapshot of one version, for restore: the client writes
      it back through update_body, so the optimistic lock and editor-level
      policy apply unchanged.
      """

      argument :page_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      run fn input, context ->
        with {:ok, _page} <- Magus.Brain.get_page(input.arguments.page_id, actor: context.actor),
             {:ok, body} <-
               Magus.Brain.page_version_body(
                 input.arguments.page_id,
                 input.arguments.version_id
               ) do
          {:ok, body}
        else
          :error -> {:error, Ash.Error.Query.NotFound.exception(resource: __MODULE__)}
          {:error, _} = error -> error
        end
      end
    end

    action :save_prosemirror, :map do
      description """
      Saves a TipTap/ProseMirror document for the SvelteKit editor. Mirrors
      the classic brain_editor_save flow: the server converts the document
      to markdown (Magus.Brain.update_page_body_from_prosemirror/4) and
      writes through update_body, so the optimistic lock and every derived
      index behave identically. A stale base_version surfaces as the typed
      version_conflict RPC error. Authorization is delegated to get_page/2
      plus update_body's own editor-level policy.
      """

      argument :page_id, :uuid, allow_nil?: false
      argument :prosemirror, :map, allow_nil?: false
      argument :base_version, :integer, allow_nil?: false

      run fn input, context ->
        with {:ok, page} <- Magus.Brain.get_page(input.arguments.page_id, actor: context.actor),
             {:ok, updated} <-
               Magus.Brain.update_page_body_from_prosemirror(
                 page,
                 input.arguments.prosemirror,
                 input.arguments.base_version,
                 actor: context.actor
               ) do
          {:ok, %{id: updated.id, lock_version: updated.lock_version}}
        end
      end
    end
  end

  policies do
    bypass action([
             :generate_name,
             :read_for_scheduler,
             :read_including_trashed,
             :trashed_for_cleanup
           ]) do
      authorize_if always()
    end

    policy action([:create, :create_as_external_agent]) do
      authorize_if {Magus.Brain.Checks.ActorOwnsBrain,
                    strategy: :brain_id_argument, min_role: :editor}
    end

    policy action([
             :read,
             :for_brain,
             :by_title_in_brain,
             :by_title_in_brain_ci,
             :root_pages,
             :children_of,
             :trashed
           ]) do
      authorize_if {Magus.Brain.Checks.BrainAccessFilter, path: :direct, min_role: :viewer}
    end

    policy action([
             :update_title,
             :update_body,
             :reposition,
             :destroy,
             :move_to_parent,
             :soft_delete,
             :restore,
             :set_kind,
             :set_spec,
             :mark_delivered,
             :undeliver
           ]) do
      authorize_if {Magus.Brain.Checks.BrainAccessFilter, path: :direct, min_role: :editor}
    end

    # Generic actions — page access is checked via get_page/2 inside the run
    # (and :save_prosemirror additionally writes through the editor-gated
    # update_body action).
    policy action([:versions, :version_diff, :version_body, :save_prosemirror]) do
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :title, :string, public?: true
    attribute :slug, :string, allow_nil?: false
    attribute :position, :float, allow_nil?: false
    attribute :icon, :string, public?: true

    attribute :kind, :atom do
      description """
      A :plan page renders a structured task board; :spec page captures the
      requirements a plan implements; :page is a normal markdown page.
      """

      allow_nil? false
      default :page
      public? true
      constraints one_of: [:page, :plan, :spec]
    end

    attribute :contributor_type, :atom,
      constraints: [one_of: [:user, :custom_agent, :external_agent]]

    attribute :contributor_id, :uuid
    attribute :depth, :integer, allow_nil?: false, default: 0

    attribute :body, :string do
      description """
      Markdown body (with optional YAML frontmatter). Nullable in Phase A
      while blocks remain the source of truth; backfilled in Phase B and
      flipped to NOT NULL in Phase D.

      Constraints disable Ash's default trim + non-empty coercion: a
      markdown body's whitespace is semantic (trailing newlines, fenced
      code indentation) and "" is a valid value (clearing a page via
      `update_body` should set it to "" rather than nil).
      """

      public? true
      constraints trim?: false, allow_empty?: true
    end

    attribute :lock_version, :integer, allow_nil?: false, default: 0, public?: true

    attribute :frontmatter, :map do
      description "Cached parsed YAML frontmatter for fast filtering without re-parsing body. Populated by the Phase C save pipeline."
      allow_nil? false
      default %{}
    end

    attribute :deleted_at, :utc_datetime_usec do
      description "When set, the page is in the trash. Cleared by :restore, used by :trashed and :trashed_for_cleanup reads."
    end

    attribute :delivered_at, :utc_datetime_usec do
      description """
      Explicit delivery gate for :plan pages. When set, the page's computed
      :lifecycle is :delivered regardless of the task rollup. Set by
      :mark_delivered, cleared by :undeliver.
      """

      public? true
    end

    attribute :delivery_ref, :string do
      description "Optional human reference for what was delivered (release tag, PR link, ...). Set by :mark_delivered, cleared by :undeliver."
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :brain, Magus.Brain.BrainResource, allow_nil?: false, public?: true
    belongs_to :parent_page, __MODULE__, allow_nil?: true, public?: true

    # A :plan page points at the :spec page it implements (nullable, explicit,
    # queryable). Self-referential on Brain.Page; deleting a spec nilifies the
    # link rather than cascading (see the migration's on_delete: :nilify).
    belongs_to :spec_page, __MODULE__ do
      allow_nil? true
      public? true
    end

    has_many :blocks, Magus.Brain.Block do
      sort position: :asc
    end

    has_many :children_pages, __MODULE__, destination_attribute: :parent_page_id

    # Reverse of :spec_page: the plans that implement this spec page.
    has_many :implementing_plans, __MODULE__, destination_attribute: :spec_page_id

    # Direct tasks of a :plan page. Drives the lifecycle rollup.
    has_many :tasks, Magus.Plan.Task do
      destination_attribute :brain_page_id
    end

    # Child pages that are themselves :plan phases. The recursive lifecycle
    # rollup walks these; plain (:page) and :spec children are excluded.
    has_many :child_plan_pages, __MODULE__ do
      destination_attribute :parent_page_id
      filter expr(kind == :plan and is_nil(deleted_at))
    end
  end

  calculations do
    calculate :needs_title, :boolean do
      calculation expr(
                    is_nil(title) and
                      not is_nil(body) and
                      fragment("length(?)", body) > 100 and
                      inserted_at < ago(5, :minute)
                  )
    end

    calculate :prosemirror, :map do
      public? true
      calculation Magus.Brain.Page.Calculations.Prosemirror
    end
  end

  identities do
    identity :unique_slug_per_brain, [:brain_id, :slug], where: expr(is_nil(deleted_at))
  end
end
