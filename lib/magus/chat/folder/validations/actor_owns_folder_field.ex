defmodule Magus.Chat.Folder.Validations.ActorOwnsFolderField do
  @moduledoc """
  Validates that the folder id carried on a changeset (by default `:folder_id`)
  refers to a folder the actor owns.

  Options:
    * `:field` — attribute/argument name holding the folder id (default `:folder_id`)
    * `:required?` — when true, a nil value fails validation (default `false`)
    * `:nil_message` — message when nil and required (default "is required")
    * `:message` — message when the folder is not owned by the actor
      (default "must be a folder you own")
  """

  use Ash.Resource.Validation

  alias Magus.Chat.Checks.ActorOwnsFolder

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, opts, context) do
    field = Keyword.get(opts, :field, :folder_id)
    required? = Keyword.get(opts, :required?, false)
    nil_message = Keyword.get(opts, :nil_message, "is required")
    message = Keyword.get(opts, :message, "must be a folder you own")

    folder_id =
      Ash.Changeset.get_argument(changeset, field) ||
        Ash.Changeset.get_attribute(changeset, field)

    cond do
      is_nil(folder_id) and required? ->
        {:error, field: field, message: nil_message}

      is_nil(folder_id) ->
        :ok

      is_nil(context.actor) ->
        {:error, field: field, message: "actor is required"}

      ActorOwnsFolder.actor_owns?(context.actor, folder_id) ->
        :ok

      true ->
        {:error, field: field, message: message}
    end
  end
end
