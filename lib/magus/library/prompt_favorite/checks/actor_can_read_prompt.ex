defmodule Magus.Library.PromptFavorite.Checks.ActorCanReadPrompt do
  @moduledoc """
  Verifies that the actor can read the prompt they are trying to favorite.
  """

  use Ash.Policy.SimpleCheck

  alias Magus.Checks.Helpers

  @impl true
  def describe(_opts), do: "actor can read the target prompt"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, context, opts) do
    field = Keyword.get(opts, :field, :prompt_id)

    case Helpers.value_from_context(context, field) do
      nil ->
        false

      prompt_id ->
        case Magus.Library.get_prompt(prompt_id, actor: actor) do
          {:ok, _prompt} -> true
          {:error, _} -> false
        end
    end
  end
end
