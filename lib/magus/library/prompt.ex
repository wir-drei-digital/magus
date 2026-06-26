defmodule Magus.Library.Prompt do
  use Ash.Resource,
    domain: Magus.Library,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshTypescript.Resource],
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  postgres do
    table "prompts"
    repo Magus.Repo
  end

  paper_trail do
    primary_key_type :uuid_v7
    change_tracking_mode :changes_only
    store_action_name? true
    reference_source? false
    ignore_attributes [:inserted_at, :updated_at, :embedding]
    belongs_to_actor :user, Magus.Accounts.User, domain: Magus.Accounts
  end

  typescript do
    type_name "Prompt"
  end

  actions do
    destroy :destroy do
      primary? true
      require_atomic? false
      change {Magus.Workspaces.Changes.DestroyResourceGrants, resource_type: :prompt}
    end

    read :read do
      primary? true
    end

    read :my_prompts do
      filter expr(user_id == ^actor(:id) and is_nil(workspace_id))
    end

    read :workspace_prompts do
      description "List prompts scoped to a workspace (read authorization governed by policies)"
      argument :workspace_id, :uuid, allow_nil?: false
      filter expr(workspace_id == ^arg(:workspace_id))
      prepare build(load: [:is_shared_to_workspace])
    end

    read :workspace_prompts_by_type do
      description "List workspace prompts filtered by type"
      argument :workspace_id, :uuid, allow_nil?: false

      argument :type, :atom do
        constraints one_of: [:system, :user]
        allow_nil? false
      end

      filter expr(workspace_id == ^arg(:workspace_id) and type == ^arg(:type))
      prepare build(load: [:is_shared_to_workspace])
    end

    read :my_prompts_by_type do
      argument :type, :atom do
        constraints one_of: [:system, :user]
        allow_nil? false
      end

      filter expr(user_id == ^actor(:id) and type == ^arg(:type))
    end

    read :my_system_prompts do
      filter expr(user_id == ^actor(:id) and type == :system)
    end

    read :my_user_prompts do
      filter expr(user_id == ^actor(:id) and type == :user)
    end

    read :public_prompts do
      filter expr(is_public == true)
    end

    read :highlighted_prompts do
      filter expr(is_public == true and is_highlighted == true)
    end

    read :public_search do
      argument :query, :string do
        allow_nil? true
      end

      argument :type, :atom do
        constraints one_of: [:system, :user]
        allow_nil? true
      end

      argument :tag_ids, {:array, :uuid} do
        allow_nil? true
        default []
      end

      argument :sort_by, :atom do
        constraints one_of: [:recent, :popular, :name]
        default :recent
      end

      filter expr(is_public == true)

      prepare fn query, _context ->
        require Ash.Query

        query =
          case Ash.Query.get_argument(query, :query) do
            nil ->
              query

            "" ->
              query

            search_term ->
              Ash.Query.filter(
                query,
                contains(name, ^search_term) or contains(content, ^search_term)
              )
          end

        query =
          case Ash.Query.get_argument(query, :type) do
            nil -> query
            type -> Ash.Query.filter(query, type == ^type)
          end

        query =
          case Ash.Query.get_argument(query, :tag_ids) do
            nil -> query
            [] -> query
            tag_ids -> Ash.Query.filter(query, exists(prompt_tags, tag_id in ^tag_ids))
          end

        case Ash.Query.get_argument(query, :sort_by) do
          :recent -> Ash.Query.sort(query, published_at: :desc)
          :popular -> Ash.Query.sort(query, copy_count: :desc)
          :name -> Ash.Query.sort(query, name: :asc)
          _ -> Ash.Query.sort(query, published_at: :desc)
        end
      end
    end

    read :my_favorite_prompts do
      prepare fn query, context ->
        require Ash.Query
        actor_id = context.actor && context.actor.id

        if actor_id do
          query
          |> Ash.Query.filter(exists(favorites, user_id == ^actor_id))
        else
          Ash.Query.filter(query, false)
        end
      end
    end

    read :fulltext_search do
      description "Full-text search across prompts using PostgreSQL tsvector + pg_trgm"
      argument :query, :string, allow_nil?: false
      pagination offset?: true, default_limit: 20, countable: false

      prepare fn query, _context ->
        require Ash.Query

        search_term = Ash.Query.get_argument(query, :query)

        query
        |> Ash.Query.filter(
          fragment(
            "search_vector @@ plainto_tsquery('simple', ?) OR similarity(name, ?) > 0.3 OR similarity(content, ?) > 0.2",
            ^search_term,
            ^search_term,
            ^search_term
          )
        )
      end
    end

    create :create do
      accept [
        :name,
        :content,
        :type,
        :metadata,
        :variables,
        :chat_mode,
        :model_id,
        :description,
        :user_message_template,
        :additional_information,
        :language,
        :workspace_id
      ]

      change relate_actor(:user)

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, prompt ->
          if prompt.user_id do
            Magus.FeatureUsage.track(prompt.user_id, "prompts", "create")
          end

          {:ok, prompt}
        end)
      end
    end

    create :copy_to_library do
      argument :source_prompt_id, :uuid, allow_nil?: false

      accept [
        :name,
        :content,
        :type,
        :metadata,
        :variables,
        :chat_mode,
        :model_id,
        :description,
        :user_message_template,
        :additional_information,
        :language
      ]

      change relate_actor(:user)

      change fn changeset, _context ->
        source_id = Ash.Changeset.get_argument(changeset, :source_prompt_id)
        Ash.Changeset.change_attribute(changeset, :copied_from_id, source_id)
      end

      change after_action(fn changeset, record, _context ->
               source_id = Ash.Changeset.get_argument(changeset, :source_prompt_id)

               # Increment copy count on the source prompt
               case Ash.get(Magus.Library.Prompt, source_id, authorize?: false) do
                 {:ok, source_prompt} ->
                   Ash.update(source_prompt, %{copy_count: source_prompt.copy_count + 1},
                     authorize?: false
                   )

                 _ ->
                   :ok
               end

               {:ok, record}
             end)
    end

    update :update do
      primary? true

      accept [
        :name,
        :content,
        :type,
        :metadata,
        :variables,
        :chat_mode,
        :model_id,
        :description,
        :user_message_template,
        :additional_information,
        :language
      ]
    end

    update :publish do
      accept [:is_public]
      require_atomic? false

      change fn changeset, _context ->
        if Ash.Changeset.get_attribute(changeset, :is_public) do
          Ash.Changeset.change_attribute(changeset, :published_at, DateTime.utc_now())
        else
          changeset
        end
      end

      # Generate embedding when publishing to enable similarity search
      change Magus.Library.Prompt.Changes.GenerateEmbedding
    end

    update :unpublish do
      change set_attribute(:is_public, false)
    end

    update :share_to_team do
      accept []
      require_atomic? false
      validate present(:workspace_id), message: "prompt must belong to a workspace"

      change {Magus.Workspaces.Changes.GrantWorkspaceAccess, resource_type: :prompt}
    end

    update :unshare_from_team do
      accept []
      require_atomic? false
      validate present(:workspace_id), message: "prompt must belong to a workspace"

      change {Magus.Workspaces.Changes.RevokeWorkspaceAccess, resource_type: :prompt}
    end

    update :add_tags do
      argument :tag_ids, {:array, :uuid}, allow_nil?: false
      require_atomic? false

      change manage_relationship(:tag_ids, :prompt_tags,
               type: :create,
               value_is_key: :tag_id,
               on_no_match: :create,
               on_match: :ignore,
               use_identities: [:unique_prompt_tag]
             )
    end

    update :remove_tag do
      argument :tag_id, :uuid, allow_nil?: false
      require_atomic? false

      change manage_relationship(:tag_id, :prompt_tags,
               type: :remove,
               value_is_key: :tag_id
             )
    end

    update :increment_copy_count do
      change atomic_update(:copy_count, expr(copy_count + 1))
    end

    update :increment_use_count do
      change atomic_update(:use_count, expr(use_count + 1))
    end

    read :find_similar do
      description "Find prompts similar to a given prompt using vector similarity"
      argument :prompt_id, :uuid, allow_nil?: false
      argument :query_embedding, {:array, :float}, allow_nil?: true
      argument :limit, :integer, default: 4

      filter expr(is_public == true and not is_nil(embedding))

      prepare fn query, _context ->
        require Ash.Query
        prompt_id = Ash.Query.get_argument(query, :prompt_id)
        limit = Ash.Query.get_argument(query, :limit)
        provided_embedding = Ash.Query.get_argument(query, :query_embedding)

        # Get embedding from provided argument or from the source prompt
        embedding =
          if provided_embedding do
            provided_embedding
          else
            case Ash.get(Magus.Library.Prompt, prompt_id, authorize?: false) do
              {:ok, %{embedding: emb}} when not is_nil(emb) -> emb
              _ -> nil
            end
          end

        if embedding do
          calc_args = %{query_embedding: embedding}

          query
          |> Ash.Query.filter(id != ^prompt_id)
          |> Ash.Query.load(vector_distance: calc_args)
          |> Ash.Query.sort({:vector_distance, {calc_args, :asc}})
          |> Ash.Query.limit(limit)
        else
          # No embedding available - return empty results
          %{query | sort: [], sort_input_indices: []}
          |> Ash.Query.filter(false)
          |> Ash.Query.limit(0)
        end
      end
    end

    create :create_from_message do
      description "Create a prompt from a single message"

      argument :message_id, :uuid, allow_nil?: false

      argument :type, :atom, constraints: [one_of: [:system, :user]]

      argument :name, :string
      argument :content, :string

      change relate_actor(:user)
      change Magus.Library.Prompt.Changes.CreateFromMessage
    end

    create :create_from_conversation do
      description "Create a prompt from conversation patterns"

      argument :conversation_id, :uuid, allow_nil?: false

      argument :type, :atom, constraints: [one_of: [:system, :user]]

      argument :name, :string
      argument :content, :string

      change relate_actor(:user)
      change Magus.Library.Prompt.Changes.CreateFromConversation
    end
  end

  policies do
    import Magus.Workspaces.Policies

    workspace_scoped_policies(
      resource_type: :prompt,
      extra_read: [
        quote do
          authorize_if expr(is_public == true)
        end
      ]
    )
  end

  pub_sub do
    module MagusWeb.Endpoint
    prefix "workspaces"

    # Minimal payload by design: subscribers refetch on receipt rather than render
    # directly from broadcasts, so we intentionally omit the prompt's body/title.
    publish_all :create, [:workspace_id, "prompts"] do
      filter fn %{data: p} -> not is_nil(p.workspace_id) end
      transform fn %{data: p} -> %{id: p.id, workspace_id: p.workspace_id, action: :created} end
    end

    publish_all :update, [:workspace_id, "prompts"] do
      filter fn %{data: p} -> not is_nil(p.workspace_id) end
      transform fn %{data: p} -> %{id: p.id, workspace_id: p.workspace_id, action: :updated} end
    end

    publish_all :destroy, [:workspace_id, "prompts"] do
      filter fn %{data: p} -> not is_nil(p.workspace_id) end
      transform fn %{data: p} -> %{id: p.id, workspace_id: p.workspace_id, action: :deleted} end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      description "The name of the prompt"
      public? true
    end

    attribute :content, :string do
      allow_nil? false
      description "The content/prompt text of the prompt"
      public? true
    end

    attribute :type, :atom do
      constraints one_of: [:system, :user]
      allow_nil? false

      description "The type of the prompt - :system for persona-like prompts, :user for general prompts"

      public? true
    end

    attribute :chat_mode, :atom do
      constraints one_of: [:chat, :search, :reasoning, :image_generation, :video_generation]
      allow_nil? true
      description "Optional preset chat mode for system prompts"
      public? true
    end

    attribute :metadata, :map do
      allow_nil? true
      default %{}
      description "Additional metadata for the prompt"
    end

    attribute :variables, :map do
      allow_nil? true
      default %{}
      description "Variables associated with the prompt"
    end

    attribute :is_public, :boolean do
      default false
      description "Whether the prompt is publicly visible in the library"
      public? true
    end

    attribute :published_at, :utc_datetime_usec do
      allow_nil? true
      description "When the prompt was made public"
      public? true
    end

    attribute :is_highlighted, :boolean do
      default false
      description "Whether the prompt is featured/highlighted by admin"
      public? true
    end

    attribute :copy_count, :integer do
      default 0
      description "Number of times this prompt has been copied"
      public? true
    end

    attribute :use_count, :integer do
      default 0
      description "Number of times this prompt has been used (activated or inserted)"
      public? true
    end

    attribute :description, :string do
      allow_nil? true
      description "Detailed description of what the prompt does"
      public? true
    end

    attribute :user_message_template, :string do
      allow_nil? true
      description "Template for user messages with {{VARIABLE}} placeholders"
      public? true
    end

    attribute :additional_information, :string do
      allow_nil? true
      description "Additional information about the prompt (markdown supported)"
      public? true
    end

    attribute :language, :atom do
      constraints one_of: [:en, :de, :es, :fr, :zh, :ja, :ko, :pt, :ru, :ar]
      allow_nil? true
      default :en
      description "Language of the prompt"
      public? true
    end

    attribute :embedding, Magus.Files.Types.Vector do
      allow_nil? true
      description "Vector embedding for similarity search"
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Magus.Accounts.User do
      allow_nil? false
    end

    belongs_to :copied_from, __MODULE__ do
      allow_nil? true
      description "The original prompt this was copied from"
    end

    has_many :copies, __MODULE__ do
      destination_attribute :copied_from_id
      description "Prompts that were copied from this one"
    end

    belongs_to :model, Magus.Chat.Model do
      allow_nil? true
      description "Optional preset model for system prompts"
      public? true
    end

    has_many :prompt_tags, Magus.Library.PromptTag

    many_to_many :tags, Magus.Library.Tag do
      public? true
      through Magus.Library.PromptTag
      source_attribute_on_join_resource :prompt_id
      destination_attribute_on_join_resource :tag_id
    end

    has_many :favorites, Magus.Library.PromptFavorite

    belongs_to :workspace, Magus.Workspaces.Workspace do
      allow_nil? true
      public? true
    end
  end

  calculations do
    import Magus.Workspaces.Calculations

    is_shared_to_workspace(:prompt)

    calculate :favorite_count, :integer, expr(count(favorites))

    calculate :vector_distance, :float do
      argument :query_embedding, {:array, :float}, allow_nil?: false

      # Cosine distance using pgvector <=> operator for semantic search
      calculation expr(fragment("(embedding <=> ?::vector)", ^arg(:query_embedding)))
    end

    calculate :is_favorited, :boolean do
      public? true

      calculation fn records, context ->
        require Ash.Query
        actor_id = context.actor && context.actor.id

        if actor_id do
          # Load favorites for all records in bulk - filter by prompt_ids in DB
          prompt_ids = Enum.map(records, & &1.id)

          favorite_prompt_ids =
            Magus.Library.PromptFavorite
            |> Ash.Query.for_read(:read)
            |> Ash.Query.filter(user_id == ^actor_id and prompt_id in ^prompt_ids)
            |> Ash.read!(authorize?: false)
            |> Enum.map(& &1.prompt_id)
            |> MapSet.new()

          Enum.map(records, fn record ->
            MapSet.member?(favorite_prompt_ids, record.id)
          end)
        else
          Enum.map(records, fn _ -> false end)
        end
      end
    end
  end
end
