defmodule MagusWeb.AgentEditHelpers do
  @moduledoc """
  Agent profile-image URL resolution, used by the workbench agent view.

  (The agent edit LiveViews this helper was originally extracted for have been
  retired; only `agent_image_url/1` is still used.)
  """

  @doc """
  Resolves the agent's profile image URL from storage, or nil.
  """
  def agent_image_url(nil), do: nil

  def agent_image_url(image_path) do
    case Magus.Files.Storage.get_url(image_path) do
      {:ok, url} -> url
      _ -> nil
    end
  end
end
