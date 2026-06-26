defmodule Magus.Files.File.Actions.LoadFirstImageDataUri do
  @moduledoc """
  Loads the first image file as a data URI.

  Used for image-to-video models that require a data URI input.
  Returns nil if no image files found.

  The inner read uses the calling actor so file ACLs are enforced. AI agent
  callers still pass via the `IsAiAgent` bypass on `Magus.Files.File`.
  """
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  @impl true
  def run(input, _opts, context) do
    ids = input.arguments.ids

    if ids == [] do
      {:ok, nil}
    else
      result =
        Magus.Files.File
        |> Ash.Query.filter(id in ^ids and type == :image)
        |> Ash.Query.load(:data_uri)
        |> Ash.Query.limit(1)
        |> Ash.read!(actor: context.actor)
        |> case do
          [file] -> file.data_uri
          [] -> nil
        end

      {:ok, result}
    end
  end
end
