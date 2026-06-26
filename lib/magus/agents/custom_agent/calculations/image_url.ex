defmodule Magus.Agents.CustomAgent.Calculations.ImageUrl do
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:image_path]

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn record ->
      case record.image_path do
        nil ->
          nil

        path ->
          case Magus.Files.Storage.get_url(path) do
            {:ok, url} -> url
            _ -> nil
          end
      end
    end)
  end
end
