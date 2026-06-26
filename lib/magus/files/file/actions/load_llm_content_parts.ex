defmodule Magus.Files.File.Actions.LoadLlmContentParts do
  @moduledoc """
  Loads files by IDs and returns their LLM content parts.

  The inner read uses the calling actor so file ACLs are enforced. AI agent
  callers still pass via the `IsAiAgent` bypass on `Magus.Files.File`. Files
  the actor cannot read are silently dropped from the result.
  """
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  @impl true
  def run(input, _opts, context) do
    ids = input.arguments.ids

    if ids == [] do
      {:ok, []}
    else
      parts =
        Magus.Files.File
        |> Ash.Query.filter(id in ^ids)
        |> Ash.Query.load(:llm_content_part)
        |> Ash.read!(actor: context.actor)
        |> Enum.map(& &1.llm_content_part)
        |> Enum.reject(&is_nil/1)

      {:ok, parts}
    end
  end
end
