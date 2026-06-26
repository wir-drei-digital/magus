defmodule MagusWeb.Workbench.Resources.FileBrowserView.Entry do
  @moduledoc """
  Uniform shape used by Grid and List components. Folders and files both
  flow as `%Entry{}` so the components iterate one stream and the
  context-menu and dispatch logic operate on a uniform record.
  """

  @enforce_keys [:kind, :id, :name]
  defstruct [
    :kind,
    :id,
    :name,
    :icon,
    :badge,
    :mime_type,
    :size,
    :modified_at,
    :owner_name,
    :source,
    :file_type,
    :is_template,
    :is_shared_to_workspace,
    :thumb_url
  ]
end
