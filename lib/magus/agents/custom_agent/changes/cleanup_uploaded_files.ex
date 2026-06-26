defmodule Magus.Agents.CustomAgent.Changes.CleanupUploadedFiles do
  @moduledoc """
  On agent destroy, delete files uploaded through this agent
  (uploaded_via_agent_id == agent.id) that are not attached to any
  other agent. Files reused elsewhere, or picked from existing files
  (no uploaded_via_agent_id), are preserved.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _ctx) do
    Ash.Changeset.after_action(changeset, fn _cs, agent ->
      uploaded_files =
        Magus.Files.File
        |> Ash.Query.filter(uploaded_via_agent_id == ^agent.id)
        |> Ash.read!(authorize?: false)

      Enum.each(uploaded_files, fn file ->
        attached_elsewhere? =
          Magus.Agents.CustomAgentAttachment
          |> Ash.Query.filter(file_id == ^file.id and custom_agent_id != ^agent.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)
          |> case do
            nil -> false
            _ -> true
          end

        unless attached_elsewhere? do
          _ = Magus.Files.delete_file(file, authorize?: false)
        end
      end)

      {:ok, agent}
    end)
  end
end
