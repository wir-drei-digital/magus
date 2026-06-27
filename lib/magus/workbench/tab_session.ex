defmodule Magus.Workbench.TabSession do
  @moduledoc """
  Per-user, per-workspace workbench UI state: open tabs, active tab, mode, filter.
  Tabs stored as JSONB.
  """
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Workbench,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "tab_sessions"
    repo Magus.Repo
  end

  typescript do
    type_name "TabSession"
  end

  actions do
    defaults [:read]

    create :create do
      accept [:user_id, :workspace_id, :mode, :nav_filter, :tabs, :active_tab_id]
    end

    create :get_or_create do
      accept [:user_id, :workspace_id]
      upsert? true
      upsert_identity :tab_sessions_user_workspace_unique
      upsert_fields []
    end

    read :for_user_workspace do
      argument :workspace_id, :uuid, allow_nil?: true

      get? true

      filter expr(
               user_id == ^actor(:id) and
                 ((is_nil(workspace_id) and is_nil(^arg(:workspace_id))) or
                    workspace_id == ^arg(:workspace_id))
             )
    end

    update :set_mode do
      accept [:mode]
    end

    update :set_nav_filter do
      accept [:nav_filter]
    end

    update :open_tab do
      require_atomic? false
      argument :primary, :map, allow_nil?: false
      argument :label, :string, allow_nil?: true

      # When true, trim the session to just the opened/activated tab in this
      # single action (classic maybe_trim_to_active_tab parity). Lets the SPA
      # open a tab with tabs disabled in one round trip instead of a follow-up
      # replace_tabs call.
      argument :single, :boolean, allow_nil?: true, default: false
      change Magus.Workbench.TabSession.Changes.OpenTab
    end

    update :activate_tab do
      require_atomic? false
      argument :tab_id, :string, allow_nil?: false
      change Magus.Workbench.TabSession.Changes.ActivateTab
    end

    update :close_tab do
      require_atomic? false
      argument :tab_id, :string, allow_nil?: false
      change Magus.Workbench.TabSession.Changes.CloseTab
    end

    update :set_companion do
      argument :tab_id, :string, allow_nil?: false
      argument :companion, :map, allow_nil?: true
      require_atomic? false
      change Magus.Workbench.TabSession.Changes.SetCompanion
    end

    update :reorder_tabs do
      argument :order, {:array, :string}, allow_nil?: false
      require_atomic? false
      change Magus.Workbench.TabSession.Changes.ReorderTabs
    end

    update :replace_tabs do
      description "Replace the tabs array and active_tab_id wholesale (used for workspace-scope cleanup)."
      argument :tabs, {:array, :map}, allow_nil?: false
      argument :active_tab_id, :string, allow_nil?: true
      require_atomic? false

      change set_attribute(:tabs, arg(:tabs))
      change set_attribute(:active_tab_id, arg(:active_tab_id))
    end

    update :update_primary do
      require_atomic? false
      argument :tab_id, :string, allow_nil?: false
      argument :primary, :map, allow_nil?: false
      change Magus.Workbench.TabSession.Changes.UpdatePrimary
    end
  end

  policies do
    # For reads and updates, the record already exists so we can filter on user_id
    policy action_type([:read, :update]) do
      authorize_if expr(user_id == ^actor(:id))
    end

    # For creates, there is no record yet — authorize by checking the actor matches
    # the user_id being set on the new record
    policy action_type(:create) do
      authorize_if relating_to_actor(:user)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :mode, :atom do
      constraints one_of: [:chat, :brain, :agents, :prompts, :files, :skills]
      default :chat
      allow_nil? false
      public? true
    end

    attribute :nav_filter, :atom do
      constraints one_of: [:all, :shared, :personal]
      default :all
      allow_nil? false
      public? true
    end

    attribute :tabs, {:array, :map} do
      default []
      allow_nil? false
      public? true
    end

    attribute :active_tab_id, :string do
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Magus.Accounts.User do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :workspace, Magus.Workspaces.Workspace do
      attribute_writable? true
    end
  end

  identities do
    identity :tab_sessions_user_workspace_unique, [:user_id, :workspace_id], nils_distinct?: false
  end
end
