defmodule Magus.Knowledge.KnowledgeCollection.Checks.ActorCanAccessSource do
  @moduledoc """
  Verifies that the actor can access the target knowledge source.
  """

  use Ash.Policy.SimpleCheck

  alias Magus.Checks.Helpers

  @impl true
  def describe(_opts), do: "actor can access the target knowledge source"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, context, opts) do
    field = Keyword.get(opts, :field, :knowledge_source_id)

    case Helpers.value_from_context(context, field) do
      nil -> false
      knowledge_source_id -> match_source?(knowledge_source_id, actor)
    end
  end

  defp match_source?(knowledge_source_id, actor) do
    case Magus.Knowledge.get_source(knowledge_source_id, actor: actor) do
      {:ok, _source} -> true
      {:error, _} -> false
    end
  end
end
