defmodule Magus.Chat.ConversationFavorite do
  @moduledoc """
  Tracks user favorites for conversations.
  """
  use Ash.Resource,
    domain: Magus.Chat,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "conversation_favorites"
    repo Magus.Repo

    references do
      reference :user, on_delete: :delete
      reference :conversation, on_delete: :delete
    end
  end

  typescript do
    type_name "ConversationFavorite"
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
    end

    read :my_favorites do
      filter expr(user_id == ^actor(:id))
    end

    read :by_conversation do
      argument :conversation_id, :uuid, allow_nil?: false
      filter expr(user_id == ^actor(:id) and conversation_id == ^arg(:conversation_id))
    end

    create :create do
      accept [:conversation_id]
      change relate_actor(:user)
    end

    action :unfavorite_by_conversation, :atom do
      description "Single-RPC unfavorite: destroys the actor's favorite for a conversation, no list fetch."
      constraints one_of: [:ok]
      argument :conversation_id, :uuid, allow_nil?: false

      run fn input, ctx ->
        require Ash.Query

        __MODULE__
        |> Ash.Query.filter(
          user_id == ^ctx.actor.id and conversation_id == ^input.arguments.conversation_id
        )
        |> Ash.bulk_destroy!(:destroy, %{}, actor: ctx.actor, return_errors?: true)

        {:ok, :ok}
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action_type(:create) do
      # Favoriting requires read access to the conversation (the check reads
      # conversation_id off the changeset and loads it as the actor).
      authorize_if Magus.Drafts.Draft.Checks.ActorCanAccessConversation
    end

    policy action_type(:destroy) do
      authorize_if expr(user_id == ^actor(:id))
    end

    # Row ownership is enforced by the action's own filter + the inner
    # :destroy policy above; this just requires an authenticated actor.
    policy action(:unfavorite_by_conversation) do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    create_timestamp :inserted_at
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
    identity :unique_user_conversation_favorite, [:user_id, :conversation_id]
  end
end
