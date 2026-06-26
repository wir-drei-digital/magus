defmodule Magus.Chat.Message.Changes.AttachResources do
  @moduledoc """
  Attaches Memory.Resource IDs to a message's attachments field.

  This change module handles all resources attached to a message, whether they
  come from:
  - The Memory sidebar (drag-and-drop existing resources)
  - File uploads in the chat input (resources created before message send)

  Resources are stored by ID only. Content is loaded on-demand by ContentLoader
  when building LLM context, avoiding large database rows.

  ## Arguments

  - `:resources` - List of Memory.Resource structs or maps with :id field
  """
  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    resources = Ash.Changeset.get_argument(changeset, :resources) || []

    if resources == [] do
      changeset
    else
      resource_ids = extract_resource_ids(resources)

      Logger.info("AttachResources: attaching #{length(resource_ids)} resource IDs")

      existing = Ash.Changeset.get_attribute(changeset, :attachments) || []
      Ash.Changeset.change_attribute(changeset, :attachments, existing ++ resource_ids)
    end
  end

  defp extract_resource_ids(resources) do
    resources
    |> Enum.map(&get_id/1)
    |> Enum.reject(&is_nil/1)
  end

  defp get_id(%{id: id}) when is_binary(id), do: id
  defp get_id(%{"id" => id}) when is_binary(id), do: id
  defp get_id(id) when is_binary(id), do: id
  defp get_id(_), do: nil
end
