defmodule Magus.Chat.Checks.ActorOwnsFolder do
  @moduledoc """
  Verifies that the actor owns the target folder.
  """

  use Ash.Policy.SimpleCheck

  alias Magus.Checks.Helpers

  @impl true
  def describe(_opts), do: "actor owns the target folder"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, context, opts) do
    field = Keyword.get(opts, :field, :folder_id)
    allow_nil? = Keyword.get(opts, :allow_nil?, false)

    case Helpers.value_from_context(context, field) do
      nil -> allow_nil?
      folder_id -> actor_owns?(actor, folder_id)
    end
  end

  def actor_owns?(%{id: actor_id} = actor, folder_id) when not is_nil(folder_id) do
    case Magus.Chat.get_folder(folder_id, actor: actor) do
      {:ok, folder} -> folder.user_id == actor_id
      {:error, _} -> false
    end
  end

  def actor_owns?(_actor, _folder_id), do: false
end
