defmodule Magus.Files.File.Calculations.DisplayInfo do
  @moduledoc """
  Returns display-ready information for a file.

  Generates a map with id, type, name, url, mime_type, and size
  suitable for rendering in UI components.
  """
  use Ash.Resource.Calculation

  alias Magus.Files.Storage

  @impl true
  def load(_query, _opts, _context) do
    [:id, :type, :name, :file_path, :mime_type, :file_size]
  end

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn file ->
      url =
        case Storage.get_url(file.file_path) do
          {:ok, url} -> url
          _ -> nil
        end

      %{
        "id" => file.id,
        "type" => to_string(file.type),
        "name" => file.name,
        "url" => url,
        "mime_type" => file.mime_type,
        "size" => file.file_size
      }
    end)
  end
end
