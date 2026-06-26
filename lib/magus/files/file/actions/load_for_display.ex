defmodule Magus.Files.File.Actions.LoadForDisplay do
  @moduledoc """
  Loads files by IDs and returns display-ready maps for the UI.

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
      files =
        Magus.Files.File
        |> Ash.Query.filter(id in ^ids)
        |> Ash.Query.load(:display_info)
        |> Ash.read!(actor: context.actor)
        |> Enum.map(& &1.display_info)

      {:ok, files}
    end
  end
end
