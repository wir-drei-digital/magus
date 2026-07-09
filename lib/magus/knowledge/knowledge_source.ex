defmodule Magus.Knowledge.KnowledgeSource do
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Knowledge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "knowledge_sources"
    repo Magus.Repo
  end

  typescript do
    type_name "KnowledgeSource"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:name, :provider, :auth_config, :settings, :workspace_id]

      change relate_actor(:user)
      change set_attribute(:status, :pending)
    end

    update :update_status do
      accept [:status, :last_error]
      require_atomic? false

      change fn changeset, _context ->
        if Ash.Changeset.get_attribute(changeset, :status) == :active do
          Ash.Changeset.force_change_attribute(changeset, :connected_at, DateTime.utc_now())
        else
          changeset
        end
      end
    end

    update :update_auth_config do
      accept [:auth_config]
      require_atomic? false
    end

    update :mark_needs_reauth do
      accept [:last_error]
      require_atomic? false
      change set_attribute(:needs_reauth, true)
      change set_attribute(:status, :error)
    end

    update :clear_reauth do
      accept []
      require_atomic? false
      change set_attribute(:needs_reauth, false)
      change set_attribute(:status, :active)
    end

    read :for_user do
      filter expr(user_id == ^actor(:id))
    end

    read :for_workspace do
      argument :workspace_id, :uuid, allow_nil?: false
      filter expr(workspace_id == ^arg(:workspace_id))
    end

    # --- SPA connect wizard: validate credentials, browse folders, sync. ---

    action :connect_source, :map do
      description "Validate API-key/URL credentials via the connector, then create + activate a source."
      argument :provider, :string, allow_nil?: false
      argument :auth_config, :map, allow_nil?: false
      argument :name, :string, allow_nil?: true, default: nil
      argument :workspace_id, :uuid, allow_nil?: true, default: nil

      run fn input, context ->
        case Magus.Knowledge.Connect.connect_and_create(
               input.arguments.provider,
               input.arguments.auth_config,
               actor: context.actor,
               name: input.arguments[:name],
               workspace_id: input.arguments[:workspace_id]
             ) do
          {:ok, source} -> {:ok, source_summary(source)}
          {:error, message} -> {:error, message}
        end
      end
    end

    action :source_folders, {:array, :map} do
      description "Browse folders for a connected source (lazy; nil parent = root)."
      argument :source_id, :uuid, allow_nil?: false
      argument :parent_id, :string, allow_nil?: true, default: nil

      run fn input, context ->
        with {:ok, source} <-
               Magus.Knowledge.get_source(input.arguments.source_id, actor: context.actor),
             {:ok, folders} <-
               Magus.Knowledge.Connect.list_folders(source, input.arguments[:parent_id]) do
          {:ok, Enum.map(folders, &folder_node/1)}
        end
      end
    end

    action :create_source_collections, :map do
      description "Create + sync a collection for each selected folder (dedup by external_id)."
      argument :source_id, :uuid, allow_nil?: false
      argument :folders, {:array, :map}, allow_nil?: false

      run fn input, context ->
        with {:ok, source} <-
               Magus.Knowledge.get_source(input.arguments.source_id, actor: context.actor) do
          {:ok, %{created: sync_folders(source, input.arguments.folders, context.actor)}}
        end
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:user)

      authorize_if expr(
                     not is_nil(workspace_id) and
                       exists(workspace.members, is_active == true and user_id == ^actor(:id))
                   )
    end

    policy action_type(:create) do
      authorize_if {Magus.Checks.ActorIsActiveWorkspaceMember, allow_nil?: true}
    end

    policy action_type([:update, :destroy]) do
      authorize_if Magus.Checks.ActorCanManageWorkspaceResource
    end

    # The connect-wizard generic actions enforce real authorization internally
    # (create_source / get_source run with the actor through these same policies).
    policy action([:connect_source, :source_folders, :create_source_collections]) do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :provider, :atom do
      constraints one_of: [
                    :google_drive,
                    :onedrive,
                    :dropbox,
                    :nextcloud,
                    :notion,
                    :confluence,
                    :github,
                    :gitlab,
                    :affine,
                    :obsidian,
                    :web
                  ]

      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:pending, :active, :error, :disabled]
      allow_nil? false
      default :pending
      public? true
    end

    attribute :auth_config, Magus.Integrations.EncryptedMap do
      allow_nil? false
      public? false
      description "Encrypted OAuth tokens, API keys, base URLs"
    end

    attribute :settings, :map do
      default %{}
      public? true
      description "Provider-specific config: domain, org, etc."
    end

    attribute :last_error, :string do
      public? true
    end

    attribute :needs_reauth, :boolean do
      allow_nil? false
      default false
      public? true

      description "Set when the OAuth refresh token is dead and the user must reconnect. Pauses scheduling."
    end

    attribute :connected_at, :utc_datetime_usec do
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Magus.Accounts.User do
      allow_nil? false
    end

    belongs_to :workspace, Magus.Workspaces.Workspace do
      allow_nil? true
      public? true
    end

    has_many :collections, Magus.Knowledge.KnowledgeCollection
  end

  defp source_summary(source) do
    %{
      id: source.id,
      name: source.name,
      provider: to_string(source.provider),
      status: to_string(source.status)
    }
  end

  defp folder_node(folder) do
    %{id: folder.id, name: folder.name, path: folder.path}
  end

  # Create + sync a collection per selected folder, deduping by external_id
  # (re-triggers a sync for an existing, non-syncing one). Mirrors the classic
  # ConnectSourceWizard "start_sync". Folder maps arrive from RPC with string
  # keys. Returns the count processed.
  defp sync_folders(source, folders, actor) do
    existing =
      case Magus.Knowledge.list_collections_for_source(source.id, actor: actor) do
        {:ok, collections} -> Map.new(collections, &{&1.external_id, &1})
        _ -> %{}
      end

    Enum.reduce(folders, 0, fn folder, count ->
      external_id = folder["id"] || folder[:id]
      name = folder["name"] || folder[:name] || external_id
      path = folder["path"] || folder[:path] || ""

      case Map.get(existing, external_id) do
        %{sync_status: :syncing} ->
          count

        %{} = collection ->
          Magus.Knowledge.trigger_full_sync(collection, actor: actor)
          count + 1

        nil ->
          case Magus.Knowledge.create_collection(
                 source.id,
                 %{name: name, external_id: external_id, external_path: path},
                 actor: actor
               ) do
            {:ok, collection} ->
              Magus.Knowledge.trigger_full_sync(collection, actor: actor)
              count + 1

            _ ->
              count
          end
      end
    end)
  end
end
