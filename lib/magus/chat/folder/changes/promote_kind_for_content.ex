defmodule Magus.Chat.Folder.Changes.PromoteKindForContent do
  @moduledoc """
  When a `File` (`content_kind: :files`) or `Conversation` (`content_kind:
  :conversations`) is placed into a folder whose kind is the *opposite*,
  silently promote that folder to `:mixed`.

  No-op when:
    - `folder_id` is nil or unchanged on update
    - the folder's kind is already `:mixed` or matches the content kind

  Runs `after_action` on the create/update of the content resource so the
  folder change happens in the same transaction as the move.
  """
  use Ash.Resource.Change

  require Ash.Query
  require Logger

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :content_kind) do
      {:ok, kind} when kind in [:files, :conversations] -> {:ok, opts}
      _ -> {:error, "content_kind must be :files or :conversations"}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    content_kind = Keyword.fetch!(opts, :content_kind)

    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      maybe_promote(Map.get(record, :folder_id), content_kind)
      {:ok, record}
    end)
  end

  defp maybe_promote(nil, _), do: :ok

  defp maybe_promote(folder_id, content_kind) do
    case Magus.Chat.get_folder(folder_id, authorize?: false) do
      {:ok, %{kind: :mixed}} ->
        :ok

      {:ok, %{kind: ^content_kind}} ->
        :ok

      {:ok, folder} ->
        Magus.Chat.promote_folder_to_mixed!(folder, authorize?: false)
        :ok

      other ->
        Logger.warning(
          "PromoteKindForContent: skipping promotion for folder_id=#{inspect(folder_id)} (#{inspect(other)})"
        )

        :ok
    end
  end
end
