defmodule Magus.MCP.Server do
  @moduledoc """
  A remote MCP server a user has registered. Holds only shared, non-secret
  configuration and the offline tool-definition cache. Per-user secrets live on
  `Magus.MCP.ServerCredential`, never here, because this row is readable by any
  workspace member at the `:viewer` role.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.MCP,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "mcp_servers"
    repo Magus.Repo

    identity_wheres_to_sql unique_handle_personal: "workspace_id IS NULL",
                           unique_handle_per_workspace: "workspace_id IS NOT NULL"

    references do
      reference :user, on_delete: :delete
      reference :workspace, on_delete: :delete
    end
  end

  typescript do
    type_name "MCPServer"

    # Elixir-style `?` attribute names are invalid TypeScript identifiers.
    field_names enabled?: "enabled"
  end

  actions do
    read :read do
      primary? true
    end

    read :my_servers do
      filter expr(user_id == ^actor(:id) and is_nil(workspace_id))
    end

    read :workspace_servers do
      argument :workspace_id, :uuid, allow_nil?: false
      filter expr(workspace_id == ^arg(:workspace_id))
    end

    create :create do
      accept [:name, :handle, :url, :transport, :mcp_path, :enabled?, :auth_type, :workspace_id]
      change relate_actor(:user)
      validate Magus.MCP.Server.Validations.SafeUrl
    end

    update :update do
      accept [:name, :url, :transport, :mcp_path, :enabled?, :auth_type]
      require_atomic? false
      validate Magus.MCP.Server.Validations.SafeUrl
    end

    update :set_provenance do
      accept [:source, :registry_name, :registry_version, :description, :repository_url]
      require_atomic? false
    end

    update :update_cached_tools do
      accept [:cached_tools]
      require_atomic? false

      change fn changeset, _ ->
        Ash.Changeset.force_change_attribute(changeset, :tools_cached_at, DateTime.utc_now())
      end
    end

    # Narrow write path for the OAuth discovery result (RFC 9728 + RFC 8414/OIDC).
    # Mirrors `update_cached_tools`: same workspace-scoped update policy posture,
    # accepts only the non-secret `oauth_metadata` map.
    update :cache_oauth_metadata do
      accept [:oauth_metadata]
      require_atomic? false
    end

    update :record_reachability do
      accept [:reachability, :last_error]
      require_atomic? false

      change fn changeset, _ ->
        # `last_reachable_at` means "last time the server was actually reachable",
        # so only stamp it on the success path. The :error path still updates
        # `reachability` + `last_error` but must not touch this field.
        if Ash.Changeset.get_attribute(changeset, :reachability) == :ok do
          Ash.Changeset.force_change_attribute(changeset, :last_reachable_at, DateTime.utc_now())
        else
          changeset
        end
      end
    end

    update :toggle do
      accept []
      require_atomic? false

      change fn changeset, _ ->
        current = Ash.Changeset.get_data(changeset, :enabled?)
        Ash.Changeset.change_attribute(changeset, :enabled?, !current)
      end
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      change {Magus.Workspaces.Changes.DestroyResourceGrants, resource_type: :mcp_server}
    end

    # Generic action: runs network discovery and caches the result. Generic
    # actions run arbitrary code OUTSIDE a DB transaction, so the long-lived
    # network round-trip to the remote MCP server never holds a Postgres
    # transaction open (the writes inside `discover_and_cache` are separate,
    # short update actions). Takes `mcp_server_id` and loads the server
    # actor-scoped, so a user can only discover a server they can read.
    action :discover, :struct do
      constraints instance_of: __MODULE__

      description "Connect to the server, list + cache tools, record reachability. Powers the UI's Test/Refresh button."

      argument :mcp_server_id, :uuid, allow_nil?: false

      run fn input, context ->
        actor = context.actor

        with {:ok, server} <- Magus.MCP.get_server(input.arguments.mcp_server_id, actor: actor) do
          Magus.MCP.Discovery.discover_and_cache(server, actor)
        end
      end
    end
  end

  policies do
    import Magus.Workspaces.Policies
    workspace_scoped_policies(resource_type: :mcp_server)

    # The generic `:discover` action has action type `:action`, which the
    # workspace_scoped_policies macro (read/create/update/destroy only) does not
    # cover. Ash policies are deny-by-default, so without this block discovery
    # would always be forbidden. Gate it on read access to the referenced
    # server; the action body re-loads actor-scoped as defense in depth.
    policy action(:discover) do
      authorize_if Magus.MCP.Server.Checks.ActorCanReadServer
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1
    end

    attribute :handle, :string do
      allow_nil? false
      public? true
      description "Short slug used to namespace this server's tool names. Immutable after create."
      constraints match: ~r/^[a-z][a-z0-9_]{0,23}$/
    end

    attribute :url, :string do
      allow_nil? false
      public? true
    end

    attribute :transport, :atom do
      allow_nil? false
      public? true
      default :streamable_http
      constraints one_of: [:streamable_http, :sse]
    end

    attribute :mcp_path, :string do
      allow_nil? false
      public? true
      default "/mcp"
    end

    attribute :enabled?, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :auth_type, :atom do
      allow_nil? false
      public? true
      default :none
      constraints one_of: [:none, :static_header, :oauth]
    end

    attribute :cached_tools, {:array, :map} do
      allow_nil? false
      public? true
      default []
      description "Normalized tool definitions from list_tools; powers offline catalog search."
    end

    attribute :tools_cached_at, :utc_datetime_usec, public?: true, allow_nil?: true

    attribute :oauth_metadata, :map do
      allow_nil? false
      public? true
      default %{}
      description "Server-wide OAuth discovery result (non-secret). Populated in the OAuth plan."
    end

    attribute :reachability, :atom do
      allow_nil? false
      public? true
      default :unknown
      constraints one_of: [:unknown, :ok, :error]
    end

    attribute :last_error, :string, public?: true, allow_nil?: true
    attribute :last_reachable_at, :utc_datetime_usec, public?: true, allow_nil?: true

    # Provenance: how this server was added. Non-secret, safe on the
    # `:viewer`-readable row. Populated by `Magus.MCP.Importer` for registry imports.
    attribute :source, :atom do
      allow_nil? false
      public? true
      default :manual
      constraints one_of: [:manual, :registry]
    end

    attribute :registry_name, :string do
      allow_nil? true
      public? true
      description "Reverse-DNS id of the originating registry entry (for idempotency + updates)."
    end

    attribute :registry_version, :string, public?: true, allow_nil?: true

    attribute :description, :string do
      allow_nil? true
      public? true
      description "Human description cached from the registry for the installed-list display."
    end

    attribute :repository_url, :string do
      allow_nil? true
      public? true
      description "Publisher repository link shown next to a registry-imported server."
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Magus.Accounts.User do
      public? true
      allow_nil? false
    end

    belongs_to :workspace, Magus.Workspaces.Workspace do
      public? true
      allow_nil? true
    end
  end

  identities do
    identity :unique_handle_personal, [:user_id, :handle], where: expr(is_nil(workspace_id))

    identity :unique_handle_per_workspace, [:workspace_id, :handle],
      where: expr(not is_nil(workspace_id))
  end
end
