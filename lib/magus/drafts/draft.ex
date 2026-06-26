defmodule Magus.Drafts.Draft do
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Drafts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshTypescript.Resource]

  postgres do
    table "drafts"
    repo Magus.Repo
  end

  @doc false
  # Enqueues a Super Brain extraction job for this draft after the row
  # commits.
  def enqueue_super_brain_extraction(draft_id) when is_binary(draft_id) do
    if Magus.SuperBrain.enabled?() do
      %{"resource_id" => draft_id}
      |> Magus.SuperBrain.Workers.ExtractDraft.new()
      |> Oban.insert()
    else
      :ok
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    change_tracking_mode :snapshot
    store_action_name? true
    reference_source? false
    ignore_attributes [:inserted_at, :updated_at, :metadata]
    belongs_to_actor :user, Magus.Accounts.User, domain: Magus.Accounts
  end

  typescript do
    type_name "Draft"
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
    end

    read :list_by_conversation do
      argument :conversation_id, :uuid, allow_nil?: false

      filter expr(conversation_id == ^arg(:conversation_id))
      prepare build(sort: [updated_at: :desc])
    end

    create :create do
      accept [:title]
      argument :content, :string, default: ""
      argument :conversation_id, :uuid, allow_nil?: false
      argument :user_id, :uuid

      change Magus.Drafts.Draft.Changes.ConvertToProsemirror
      change set_attribute(:conversation_id, arg(:conversation_id))
      change set_attribute(:user_id, arg(:user_id))
      change Magus.Drafts.Draft.Changes.BroadcastDraftEvent

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, draft ->
          if draft.user_id do
            Magus.FeatureUsage.track(draft.user_id, "draft_mode", "use")
          end

          {:ok, draft}
        end)
      end

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _cs, draft ->
          enqueue_super_brain_extraction(draft.id)
          {:ok, draft}
        end)
      end
    end

    update :update_content do
      accept []
      require_atomic? false

      argument :content, :string, allow_nil?: false

      change Magus.Drafts.Draft.Changes.ConvertToProsemirror
      change increment(:version)
      change Magus.Drafts.Draft.Changes.BroadcastDraftEvent

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _cs, draft ->
          enqueue_super_brain_extraction(draft.id)
          {:ok, draft}
        end)
      end
    end

    update :update_content_json do
      accept []
      require_atomic? false

      argument :content_json, :map, allow_nil?: false

      validate Magus.Drafts.Draft.Validations.ValidProsemirrorDocument

      change set_attribute(:content, arg(:content_json))
      change increment(:version)
      change Magus.Drafts.Draft.Changes.BroadcastDraftEvent

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _cs, draft ->
          enqueue_super_brain_extraction(draft.id)
          {:ok, draft}
        end)
      end
    end

    update :update_title do
      accept []
      require_atomic? false

      argument :title, :string, allow_nil?: false

      change set_attribute(:title, arg(:title))
      change Magus.Drafts.Draft.Changes.BroadcastDraftEvent
    end

    update :replace_text do
      accept []
      require_atomic? false

      argument :old_text, :string, allow_nil?: false
      argument :new_text, :string, allow_nil?: false, constraints: [allow_empty?: true]
      argument :hint_line, :integer

      change Magus.Drafts.Draft.Changes.ReplaceText
      change increment(:version)
      change Magus.Drafts.Draft.Changes.BroadcastDraftEvent

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _cs, draft ->
          enqueue_super_brain_extraction(draft.id)
          {:ok, draft}
        end)
      end
    end

    update :update_metadata do
      accept []
      require_atomic? false

      argument :metadata, :map, allow_nil?: false

      change set_attribute(:metadata, arg(:metadata))
    end

    update :restore_version do
      accept []
      require_atomic? false

      argument :version_id, :uuid_v7, allow_nil?: false

      change Magus.Drafts.Draft.Changes.RestoreVersion
      change increment(:version)
      change Magus.Drafts.Draft.Changes.BroadcastDraftEvent

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _cs, draft ->
          enqueue_super_brain_extraction(draft.id)
          {:ok, draft}
        end)
      end
    end

    action :request_review, :map do
      argument :draft_id, :uuid, allow_nil?: false
      argument :conversation_id, :uuid, allow_nil?: false

      run fn input, context ->
        prompt = Magus.Agents.Context.DraftPrompts.review_prompt()

        case Magus.Chat.create_draft_event_message(
               prompt,
               input.arguments.conversation_id,
               :review,
               input.arguments.draft_id,
               actor: context.actor
             ) do
          {:ok, message} -> {:ok, %{message: message}}
          {:error, error} -> {:error, error}
        end
      end
    end

    action :export, :map do
      argument :draft_id, :uuid, allow_nil?: false
      argument :conversation_id, :uuid, allow_nil?: false

      argument :export_format, :atom,
        allow_nil?: false,
        constraints: [one_of: [:pdf, :docx, :latex, :markdown]]

      run fn input, context ->
        draft_id = input.arguments.draft_id
        conv_id = input.arguments.conversation_id
        format = input.arguments.export_format
        actor = context.actor

        with {:ok, %{} = draft} <- Magus.Drafts.get_draft(draft_id, actor: actor),
             metadata =
               Map.merge(draft.metadata || %{}, %{
                 "last_exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
                 "last_exported_format" => to_string(format)
               }),
             {:ok, _} <-
               Ash.update(draft, %{metadata: metadata},
                 action: :update_metadata,
                 actor: actor
               ),
             prompt =
               Magus.Agents.Context.DraftPrompts.export_prompt(format, draft_id, draft.title),
             {:ok, message} <-
               Magus.Chat.create_draft_event_message(
                 prompt,
                 conv_id,
                 :export,
                 draft_id,
                 %{export_format: format},
                 actor: actor
               ) do
          {:ok, %{draft: draft, message: message}}
        else
          {:ok, nil} -> {:error, "Draft not found"}
          {:error, error} -> {:error, error}
        end
      end
    end
  end

  policies do
    bypass action_type([:read, :create, :update, :destroy]) do
      authorize_if Magus.Checks.IsAiAgent
    end

    policy action_type(:create) do
      authorize_if Magus.Drafts.Draft.Checks.ActorCanAccessConversation
    end

    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))

      authorize_if expr(conversation.user_id == ^actor(:id))

      authorize_if expr(
                     exists(
                       conversation.members,
                       user_id == ^actor(:id) and not is_nil(accepted_at)
                     )
                   )

      authorize_if expr(
                     not is_nil(conversation.workspace_id) and
                       conversation.is_shared_to_workspace == true and
                       exists(
                         conversation.workspace.members,
                         is_active == true and user_id == ^actor(:id)
                       )
                   )
    end

    policy action_type([:update, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end

    # Generic actions — sub-calls are individually authorized with the actor
    bypass action(:request_review) do
      authorize_if always()
    end

    bypass action(:export) do
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :content, :map do
      allow_nil? false
      default %{"type" => "doc", "content" => [%{"type" => "paragraph"}]}
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :draft
      constraints one_of: [:draft]
      public? true
    end

    attribute :version, :integer do
      allow_nil? false
      default 1
      public? true
    end

    attribute :metadata, :map do
      default %{}
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :conversation, Magus.Chat.Conversation, allow_nil?: false, public?: true
    belongs_to :user, Magus.Accounts.User, allow_nil?: true
  end
end
