defmodule Magus.Files.File.Checks.ActorManagesFile do
  @moduledoc """
  FilterCheck for `Magus.Files.File` update/destroy policies. Matches files
  the actor owns directly, workspace files where the actor is an active admin,
  or connector-synced files whose knowledge source belongs to the actor's
  workspace.
  """

  use Ash.Policy.FilterCheck

  @impl true
  def describe(_opts), do: "actor owns the file or is an admin of its workspace"

  @impl true
  def filter(actor, _authorizer, _opts) do
    actor_id = actor && actor.id

    expr(
      not is_nil(^actor_id) and
        (user_id == ^actor_id or
           (not is_nil(workspace_id) and
              exists(
                workspace.members,
                is_active == true and role == :admin and user_id == ^actor_id
              )) or
           (not is_nil(knowledge_collection_id) and
              not is_nil(knowledge_collection.knowledge_source.workspace_id) and
              exists(
                knowledge_collection.knowledge_source.workspace.members,
                is_active == true and role == :admin and user_id == ^actor_id
              )))
    )
  end
end
