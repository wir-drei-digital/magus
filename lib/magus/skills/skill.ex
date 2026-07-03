defmodule Magus.Skills.Skill do
  use Ash.Resource,
    domain: Magus.Skills,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshTypescript.Resource],
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  @authoring_fields [
    :name,
    :display_name,
    :description,
    :body,
    :requested_tools,
    :required_secrets,
    :runtime_hints,
    :metadata,
    :version,
    :license,
    :compatibility,
    :icon,
    :color,
    :source_format,
    :source_url,
    :workspace_id
  ]

  postgres do
    table "skills"
    repo Magus.Repo
  end

  typescript do
    type_name "Skill"
  end

  actions do
    defaults [:read]

    read :my_skills do
      filter expr(user_id == ^actor(:id) and is_nil(workspace_id))
    end

    read :workspace_skills do
      argument :workspace_id, :uuid, allow_nil?: false
      filter expr(workspace_id == ^arg(:workspace_id))
      prepare build(load: [:is_shared_to_workspace])
    end

    read :my_favorite_skills do
      prepare fn query, context ->
        require Ash.Query
        actor_id = context.actor && context.actor.id

        if actor_id do
          Ash.Query.filter(query, exists(favorites, user_id == ^actor_id))
        else
          Ash.Query.filter(query, false)
        end
      end
    end

    read :fulltext_search do
      description "Search skills by name/display name/description/body (pg_trgm + substring)"
      argument :query, :string, allow_nil?: false
      pagination offset?: true, default_limit: 20, countable: false

      prepare fn query, _context ->
        require Ash.Query

        search_term = Ash.Query.get_argument(query, :query)

        Ash.Query.filter(
          query,
          fragment(
            "similarity(name, ?) > 0.25 OR similarity(coalesce(display_name, ''), ?) > 0.25 OR similarity(coalesce(description, ''), ?) > 0.2 OR coalesce(body, '') ILIKE '%' || ? || '%'",
            ^search_term,
            ^search_term,
            ^search_term,
            ^search_term
          )
        )
      end
    end

    update :share_to_team do
      accept []
      require_atomic? false
      validate present(:workspace_id), message: "skill must belong to a workspace"
      change {Magus.Workspaces.Changes.GrantWorkspaceAccess, resource_type: :skill}
    end

    update :unshare_from_team do
      accept []
      require_atomic? false
      validate present(:workspace_id), message: "skill must belong to a workspace"
      change {Magus.Workspaces.Changes.RevokeWorkspaceAccess, resource_type: :skill}
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      change {Magus.Workspaces.Changes.DestroyResourceGrants, resource_type: :skill}
    end

    create :create do
      primary? true
      accept @authoring_fields
      change relate_actor(:user)
    end

    create :import do
      description "Create a skill from an imported bundle (accepts bundle fields)."

      accept @authoring_fields ++
               [
                 :bundle_path,
                 :bundle_backend,
                 :bundle_byte_size,
                 :file_manifest,
                 :has_executable_bundle
               ]

      change relate_actor(:user)
    end

    update :update do
      primary? true
      require_atomic? false

      accept [
        :name,
        :display_name,
        :description,
        :body,
        :requested_tools,
        :required_secrets,
        :runtime_hints,
        :metadata,
        :version,
        :license,
        :compatibility,
        :icon,
        :color
      ]
    end
  end

  policies do
    import Magus.Workspaces.Policies

    workspace_scoped_policies(resource_type: :skill)
  end

  pub_sub do
    module MagusWeb.Endpoint
    prefix "workspaces"

    publish_all :create, [:workspace_id, "skills"] do
      filter fn %{data: s} -> not is_nil(s.workspace_id) end
      transform fn %{data: s} -> %{id: s.id, workspace_id: s.workspace_id, action: :created} end
    end

    publish_all :update, [:workspace_id, "skills"] do
      filter fn %{data: s} -> not is_nil(s.workspace_id) end
      transform fn %{data: s} -> %{id: s.id, workspace_id: s.workspace_id, action: :updated} end
    end

    publish_all :destroy, [:workspace_id, "skills"] do
      filter fn %{data: s} -> not is_nil(s.workspace_id) end
      transform fn %{data: s} -> %{id: s.id, workspace_id: s.workspace_id, action: :deleted} end
    end
  end

  validations do
    validate match(:name, ~r/^[a-z0-9-]{1,64}$/) do
      message "must be lowercase letters, numbers, and hyphens, at most 64 characters"
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "SKILL.md name: lowercase, numbers, hyphens, max 64 chars"
    end

    attribute :display_name, :string do
      allow_nil? true
      public? true
    end

    attribute :description, :string do
      allow_nil? false
      public? true
      description "One-line description; drives discovery"
    end

    attribute :body, :string do
      allow_nil? true
      public? true
      description "The SKILL.md markdown body (instructions)"
    end

    attribute :requested_tools, {:array, :string} do
      allow_nil? true
      default []
      public? true
      description "Existing Magus tools the skill wants (maps to SKILL.md allowed-tools)"
    end

    attribute :required_secrets, {:array, :map} do
      allow_nil? true
      default []
      public? true
      description "Declarative hints [%{key, description}]; no values stored"
    end

    attribute :runtime_hints, :map do
      allow_nil? true
      default %{}
      description "Optional %{packages: [...], image: ...}"
    end

    attribute :metadata, :map do
      allow_nil? true
      default %{}
      description "Standard SKILL.md metadata passthrough"
    end

    attribute :version, :string do
      allow_nil? true
      public? true
    end

    attribute :license, :string do
      allow_nil? true
      public? true
    end

    attribute :compatibility, :string do
      allow_nil? true
      public? true
    end

    attribute :icon, :string do
      allow_nil? true
      public? true
    end

    attribute :color, :string do
      allow_nil? true
      public? true
    end

    attribute :source_format, :atom do
      constraints one_of: [:skill_md, :agents_md, :goose, :other]
      default :skill_md
      allow_nil? false
      public? true
    end

    attribute :source_url, :string do
      allow_nil? true
      public? true
    end

    attribute :has_executable_bundle, :boolean do
      default false
      allow_nil? false
      public? true
    end

    attribute :bundle_path, :string do
      allow_nil? true
    end

    attribute :bundle_backend, :string do
      allow_nil? true
    end

    attribute :bundle_byte_size, :integer do
      allow_nil? true
    end

    attribute :file_manifest, {:array, :map} do
      allow_nil? true
      default []
      public? true
      description "[%{path, size, sha256, executable?}] for the bundle"
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

    has_many :favorites, Magus.Skills.SkillFavorite
  end

  calculations do
    import Magus.Workspaces.Calculations

    is_shared_to_workspace(:skill)

    calculate :is_favorited, :boolean do
      public? true

      calculation fn records, context ->
        require Ash.Query
        actor_id = context.actor && context.actor.id

        if actor_id do
          skill_ids = Enum.map(records, & &1.id)

          favorite_skill_ids =
            Magus.Skills.SkillFavorite
            |> Ash.Query.for_read(:read)
            |> Ash.Query.filter(user_id == ^actor_id and skill_id in ^skill_ids)
            |> Ash.read!(authorize?: false)
            |> Enum.map(& &1.skill_id)
            |> MapSet.new()

          Enum.map(records, &MapSet.member?(favorite_skill_ids, &1.id))
        else
          Enum.map(records, fn _ -> false end)
        end
      end
    end
  end
end
