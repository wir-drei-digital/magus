defmodule MagusWeb.Workbench.Modes.FilesModeNav.Data do
  @moduledoc """
  Builds the entry-point list for the Files mode sidebar.

  The sidebar surfaces a fixed set of "entry points" (My Files, Recent,
  Templates, Knowledge, Trash, plus Shared with me when in a workspace).
  When the Knowledge group is expanded, the user's KnowledgeCollections
  are loaded as nested links.
  """

  use Gettext, backend: MagusWeb.Gettext

  alias Magus.Knowledge

  @doc """
  Loads the data needed to render the Files mode sidebar.

  Returns a map with two keys:

    * `:entry_points` — the fixed list of top-level navigation items.
      In workspace mode this includes a "Shared with me" item between
      "My Files" and "Recent". In personal mode it omits "Shared with me".
    * `:collections` — a list of knowledge collections loaded only when
      the `:knowledge` entry is expanded. Otherwise `[]`.
  """
  def load(%{user: user, workspace_id: workspace_id} = opts) do
    expanded = Map.get(opts, :expanded_collection_ids, MapSet.new())

    collections =
      if MapSet.size(expanded) > 0 do
        load_collections(user, workspace_id)
      else
        []
      end

    %{
      entry_points: build_entry_points(workspace_id),
      collections: Enum.map(collections, &collection_to_item/1)
    }
  end

  defp build_entry_points(workspace_id) do
    base = [
      %{
        key: :my_files,
        label: gettext("My Files"),
        icon: "lucide-folder",
        path: "/files",
        scope: "my_files"
      },
      %{
        key: :recent,
        label: gettext("Recent"),
        icon: "lucide-clock",
        path: "/files?scope=recent",
        scope: "recent"
      },
      %{
        key: :templates,
        label: gettext("Templates"),
        icon: "lucide-star",
        path: "/files?scope=templates",
        scope: "templates"
      },
      %{
        key: :knowledge,
        label: gettext("Connected Sources"),
        icon: "lucide-brain",
        path: nil,
        scope: nil,
        expandable?: true
      },
      %{
        key: :trash,
        label: gettext("Trash"),
        icon: "lucide-trash",
        path: "/files?scope=trash",
        scope: "trash"
      }
    ]

    if workspace_id do
      shared = %{
        key: :shared,
        label: gettext("Shared with me"),
        icon: "lucide-users",
        path: "/files?scope=shared",
        scope: "shared"
      }

      [Enum.at(base, 0)] ++ [shared] ++ Enum.drop(base, 1)
    else
      base
    end
  end

  defp load_collections(user, nil), do: Knowledge.list_personal_collections!(actor: user)

  defp load_collections(user, ws_id),
    do: Knowledge.list_workspace_collections!(ws_id, actor: user)

  defp collection_to_item(coll) do
    %{
      id: coll.id,
      label: coll.name || gettext("Untitled collection"),
      icon: "lucide-files",
      path: "/files/knowledge/#{coll.id}"
    }
  end
end
