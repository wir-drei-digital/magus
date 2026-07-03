defmodule Magus.Skills.SkillFavorite.Checks.ActorCanReadSkill do
  @moduledoc """
  Verifies that the actor can read the skill they are trying to favorite.
  """

  use Ash.Policy.SimpleCheck

  alias Magus.Checks.Helpers

  @impl true
  def describe(_opts), do: "actor can read the target skill"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, context, opts) do
    field = Keyword.get(opts, :field, :skill_id)

    case Helpers.value_from_context(context, field) do
      nil ->
        false

      skill_id ->
        case Magus.Skills.get_skill(skill_id, actor: actor) do
          {:ok, _skill} -> true
          {:error, _} -> false
        end
    end
  end
end
