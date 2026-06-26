defmodule Magus.Files.File.Calculations.DataUri do
  @moduledoc """
  Calculates the data URI representation of a file.

  Returns a string like `data:image/png;base64,iVBORw0KGgo...`

  Primarily used for image-to-video models that require data URI input.
  Returns nil for non-image files or if loading fails.
  """
  use Ash.Resource.Calculation

  require Logger

  alias Magus.Files.Storage

  @impl true
  def load(_query, _opts, _context), do: [:type, :mime_type, :file_path]

  @impl true
  def calculate(files, _opts, _context) do
    Enum.map(files, &build_data_uri/1)
  end

  defp build_data_uri(%{type: :image} = file) do
    case Storage.get(file.file_path) do
      {:ok, content} when is_binary(content) ->
        "data:#{file.mime_type};base64,#{Base.encode64(content)}"

      {:error, reason} ->
        Logger.warning("Failed to load image for data URI #{file.file_path}: #{inspect(reason)}")

        nil
    end
  end

  defp build_data_uri(_file), do: nil
end
