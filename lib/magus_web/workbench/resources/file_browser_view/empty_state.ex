defmodule MagusWeb.Workbench.Resources.FileBrowserView.EmptyState do
  @moduledoc """
  Shared empty-state markup for the file browser's Grid and List views. Both
  variants render the same icon + message, picked from the current scope.
  """
  use MagusWeb, :html

  attr :scope, :string, required: true

  def empty_state(assigns) do
    ~H"""
    <div class="p-12 text-center text-wb-text-dim">
      <.icon name={empty_icon(@scope)} class="w-12 h-12 mx-auto mb-3 opacity-50" />
      <p class="text-sm">{empty_message(@scope)}</p>
    </div>
    """
  end

  defp empty_icon("trash"), do: "lucide-trash"
  defp empty_icon("templates"), do: "lucide-star"
  defp empty_icon(_), do: "lucide-folder-open"

  defp empty_message("my_files"), do: gettext("No files yet. Drag files here or click Upload.")
  defp empty_message("shared"), do: gettext("Nothing shared with you yet")
  defp empty_message("recent"), do: gettext("Nothing recent")
  defp empty_message("templates"), do: gettext("No templates")
  defp empty_message("trash"), do: gettext("Trash is empty")
  defp empty_message("knowledge"), do: gettext("This collection is empty")
  defp empty_message(_), do: gettext("This folder is empty")
end
