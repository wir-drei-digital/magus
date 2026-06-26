defmodule Magus.Memory.Memory.Changes.CreateVersion do
  @moduledoc """
  Creates a version snapshot whenever a memory is created or modified.

  The version captures the content and summary at that point in time,
  along with who made the change (agent, user, system, or extraction).
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, memory ->
      changed_by = determine_changed_by(context)

      Magus.Memory.create_memory_version!(
        %{
          memory_id: memory.id,
          content: memory.content,
          summary: memory.summary,
          version: memory.lock_version,
          changed_by: changed_by
        },
        authorize?: false
      )

      {:ok, memory}
    end)
  end

  defp determine_changed_by(%{actor: actor} = context) do
    source_context = Map.get(context, :source_context, %{})

    cond do
      Map.get(source_context, :extraction, false) -> :extraction
      Map.get(source_context, :chat_agent?, false) -> :agent
      is_user?(actor) -> :user
      true -> :system
    end
  end

  defp determine_changed_by(_), do: :system

  defp is_user?(actor) when is_struct(actor) do
    actor.__struct__ == Magus.Accounts.User
  end

  defp is_user?(_), do: false
end
