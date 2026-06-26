defmodule Magus.Chat.ConversationCompanion do
  @moduledoc """
  Links a conversation to the resource it is the chat companion to (a file
  or brain page). One row per `(user_id, resource_type, resource_id)`; a
  conversation participates in at most one such link (unique on
  `conversation_id`).
  """
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Chat,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshTypescript.Resource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "conversation_companions"
    repo Magus.Repo

    references do
      reference :user, on_delete: :delete
      reference :conversation, on_delete: :delete
    end
  end

  typescript do
    type_name "ConversationCompanion"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:resource_type, :resource_id, :conversation_id]
      change relate_actor(:user)

      validate {Magus.Chat.ConversationCompanion.Validations.ActorOwnsConversation, []}
    end

    read :by_resource do
      get? true

      argument :resource_type, :atom,
        allow_nil?: false,
        constraints: [one_of: [:file, :brain_page]]

      argument :resource_id, :uuid, allow_nil?: false

      filter expr(
               user_id == ^actor(:id) and
                 resource_type == ^arg(:resource_type) and
                 resource_id == ^arg(:resource_id)
             )
    end

    read :by_conversation_id do
      get? true
      argument :conversation_id, :uuid, allow_nil?: false

      filter expr(conversation_id == ^arg(:conversation_id) and user_id == ^actor(:id))
    end

    action :find_or_create_companion, :struct do
      constraints instance_of: __MODULE__

      argument :resource_type, :atom,
        allow_nil?: false,
        constraints: [one_of: [:file, :brain_page]]

      argument :resource_id, :uuid, allow_nil?: false

      run Magus.Chat.ConversationCompanion.Changes.FindOrCreate
    end

    action :find_or_create_companion_chat, :map do
      description """
      SPA "Open chat" button: find-or-create the companion conversation for a
      file/brain page and return just its id (the generic-action map shape the
      RPC client consumes).
      """

      argument :resource_type, :atom,
        allow_nil?: false,
        constraints: [one_of: [:file, :brain_page]]

      argument :resource_id, :uuid, allow_nil?: false

      run fn input, context ->
        case Magus.Chat.find_or_create_companion_conversation(
               input.arguments.resource_type,
               input.arguments.resource_id,
               actor: context.actor
             ) do
          {:ok, conversation} ->
            {:ok, %{conversation_id: conversation.id, title: conversation.title}}

          {:error, _} = error ->
            error
        end
      end
    end

    action :destroy_for_resource, :atom do
      description """
      System sweep: drop companion rows for the given resource across all
      users. Called from File/BrainPage destroy after_actions. Bypasses
      authorization (`authorize?: false`) because it must drop links for
      users other than the current actor.
      """

      constraints one_of: [:ok]

      argument :resource_type, :atom,
        allow_nil?: false,
        constraints: [one_of: [:file, :brain_page]]

      argument :resource_id, :uuid, allow_nil?: false

      run fn input, _ctx ->
        require Ash.Query
        require Logger

        result =
          __MODULE__
          |> Ash.Query.filter(
            resource_type == ^input.arguments.resource_type and
              resource_id == ^input.arguments.resource_id
          )
          |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false, return_errors?: true)

        case result do
          %Ash.BulkResult{status: :success} ->
            {:ok, :ok}

          %Ash.BulkResult{status: status, errors: errors} ->
            Logger.warning("companion: unlink sweep had failures",
              resource_type: input.arguments.resource_type,
              resource_id: input.arguments.resource_id,
              status: status,
              errors: inspect(errors)
            )

            {:ok, :ok}
        end
      end
    end
  end

  policies do
    policy action_type(:create) do
      authorize_if always()
    end

    policy action_type([:read, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end

    # Generic action delegates authorization to the underlying domain calls
    # (Chat.get_companion_by_resource, Chat.create_conversation, etc.).
    policy action([:find_or_create_companion, :find_or_create_companion_chat]) do
      authorize_if always()
    end

    # System sweep called from File/BrainPage destroy after_actions; bypasses
    # ownership checks because it must drop links across users.
    policy action(:destroy_for_resource) do
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :resource_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:file, :brain_page]
    end

    attribute :resource_id, :uuid do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Magus.Accounts.User do
      allow_nil? false
    end

    belongs_to :conversation, Magus.Chat.Conversation do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_companion_per_resource, [:user_id, :resource_type, :resource_id]
    identity :unique_conversation, [:conversation_id]
  end
end
