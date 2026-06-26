defmodule Magus.Accounts.User.Calculations.AvatarUrl do
  @moduledoc """
  Resolves a user's `avatar_path` to a public, servable URL (mirrors
  `Magus.Agents.CustomAgent.Calculations.ImageUrl`). Stored avatars live under
  the public `avatars/` prefix, served at `/uploads/files/`.
  """
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:avatar_path]

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn record ->
      case record.avatar_path do
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
