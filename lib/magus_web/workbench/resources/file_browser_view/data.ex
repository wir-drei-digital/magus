defmodule MagusWeb.Workbench.Resources.FileBrowserView.Data do
  @moduledoc """
  Loads entries + breadcrumbs for the file browser.

  Keys:
    * `:scope` — `"my_files" | "shared" | "recent" | "templates" | "trash" | "folder" | "knowledge"`
    * `:id` — folder/collection uuid for `folder`/`knowledge` scopes; nil otherwise
    * `:user`, `:workspace_id`
    * `:filters` — `%{"type" => ..., "modified" => ..., "source" => ...}`
    * `:sort` — `"updated_at:desc" | "name:asc" | ...`
    * `:q` — search string
  """

  use Gettext, backend: MagusWeb.Gettext

  require Ash.Query

  alias Magus.{Chat, Knowledge}
  alias MagusWeb.Workbench.Resources.FileBrowserView.Entry

  @max_entries 500

  def load(opts) do
    user = Map.fetch!(opts, :user)
    scope = Map.fetch!(opts, :scope)
    workspace_id = Map.get(opts, :workspace_id)
    filters = Map.get(opts, :filters, %{})
    sort = Map.get(opts, :sort, "updated_at:desc")
    q = Map.get(opts, :q, "") |> to_string() |> String.trim() |> String.downcase()

    {folders, files, breadcrumb_extra} =
      load_for_scope(scope, Map.get(opts, :id), user, workspace_id, filters)

    folders = folders |> filter_by_q(q) |> sort_folders(sort)
    files = files |> filter_by_q(q) |> sort_files(sort)

    entries =
      (Enum.map(folders, &folder_to_entry/1) ++ Enum.map(files, &file_to_entry/1))
      |> Enum.take(@max_entries)

    %{
      entries: entries,
      total_before_cap: length(folders) + length(files),
      breadcrumbs: breadcrumbs(scope, breadcrumb_extra, user)
    }
  end

  # ---------------------------------------------------------------------------
  # Per-scope loaders
  # ---------------------------------------------------------------------------

  defp load_for_scope("my_files", _id, user, nil, filters) do
    folders =
      Chat.my_folders!(%{kinds: [:files, :mixed]}, actor: user)
      |> Enum.filter(&is_nil(&1.parent_id))

    files =
      :personal_library_files
      |> read_files(browser_args(filters), user)
      |> Enum.filter(&is_nil(&1.folder_id))

    {folders, files, nil}
  end

  defp load_for_scope("my_files", _id, user, ws_id, filters) when not is_nil(ws_id) do
    folders =
      Chat.list_workspace_folders!(ws_id, %{kinds: [:files, :mixed]}, actor: user)
      |> Enum.filter(&(is_nil(&1.parent_id) and &1.user_id == user.id))

    files =
      :workspace_library_files
      |> read_files(Map.put(browser_args(filters), :workspace_id, ws_id), user)
      |> Enum.filter(&(is_nil(&1.folder_id) and &1.user_id == user.id))

    {folders, files, nil}
  end

  defp load_for_scope("shared", _id, user, ws_id, filters) when not is_nil(ws_id) do
    folders =
      Chat.list_workspace_folders!(ws_id, %{kinds: [:files, :mixed]}, actor: user)
      |> Enum.filter(&(is_nil(&1.parent_id) and &1.user_id != user.id))

    files =
      read_files(
        :list_shared_with_me,
        Map.put(browser_args(filters), :workspace_id, ws_id),
        user
      )

    {folders, files, nil}
  end

  defp load_for_scope("shared", _id, _user, nil, _filters), do: {[], [], nil}

  defp load_for_scope("recent", _id, user, workspace_id, filters) do
    since = DateTime.add(DateTime.utc_now(), -30, :day)

    args =
      browser_args(filters)
      |> Map.put(:workspace_id, workspace_id)
      |> Map.put(:since, since)

    {[], read_files(:list_recent, args, user), nil}
  end

  defp load_for_scope("templates", _id, user, _workspace_id, filters) do
    {[], read_files(:list_templates, browser_args(filters), user), nil}
  end

  defp load_for_scope("trash", _id, user, workspace_id, filters) do
    args = Map.put(browser_args(filters), :workspace_id, workspace_id)
    {[], read_files(:list_trash, args, user), nil}
  end

  defp load_for_scope("folder", id, user, _workspace_id, filters) when is_binary(id) do
    folders = Chat.list_folders_in_folder!(id, %{kinds: [:files, :mixed]}, actor: user)

    args = Map.put(browser_args(filters), :folder_id, id)
    files = read_files(:list_in_folder, args, user)

    folder =
      case Chat.get_folder(id, actor: user) do
        {:ok, f} -> f
        _ -> nil
      end

    {folders, files, folder}
  end

  defp load_for_scope("knowledge", id, user, _workspace_id, filters) when is_binary(id) do
    args = Map.put(browser_args(filters), :knowledge_collection_id, id)
    files = read_files(:files_for_collection, args, user)

    coll =
      case Knowledge.get_collection(id, actor: user) do
        {:ok, c} -> c
        _ -> nil
      end

    {[], files, coll}
  end

  defp load_for_scope(_unknown, _id, _user, _ws, _filters), do: {[], [], nil}

  # ---------------------------------------------------------------------------
  # Query builder
  # ---------------------------------------------------------------------------

  # Build the read query with `for_read` (which validates exactly once) and
  # call `Ash.read!` directly. Going through the domain code interface would
  # call `for_read` a second time on the already-validated query and emit
  # the "Query has already been validated" warning.
  defp read_files(action, args, actor) do
    Magus.Files.File
    |> Ash.Query.for_read(action, args, actor: actor)
    |> Ash.read!()
  end

  defp browser_args(filters) when is_map(filters) do
    %{
      browser_type: filters["type"] || filters[:type],
      browser_modified: filters["modified"] || filters[:modified],
      browser_source: filters["source"] || filters[:source]
    }
  end

  # ---------------------------------------------------------------------------
  # Entry construction
  # ---------------------------------------------------------------------------

  defp folder_to_entry(%Magus.Chat.Folder{} = f) do
    %Entry{
      kind: :folder,
      id: f.id,
      name: f.name || gettext("Untitled folder"),
      icon: "lucide-folder",
      modified_at: f.updated_at,
      is_shared_to_workspace: shared_flag(f)
    }
  end

  defp file_to_entry(%Magus.Files.File{} = f) do
    %Entry{
      kind: :file,
      id: f.id,
      name: f.name || gettext("Untitled file"),
      icon: file_icon(f),
      badge: if(f.is_template, do: "Template"),
      mime_type: f.mime_type,
      size: f.file_size,
      modified_at: f.updated_at,
      source: f.source,
      file_type: f.type,
      is_template: f.is_template,
      is_shared_to_workspace: shared_flag(f),
      thumb_url: thumb_url_for(f)
    }
  end

  defp thumb_url_for(%{type: :image, file_path: path}) when is_binary(path) do
    case Magus.Files.Storage.get_url(path) do
      {:ok, url} -> url
      _ -> nil
    end
  end

  defp thumb_url_for(_), do: nil

  defp shared_flag(%{is_shared_to_workspace: %Ash.NotLoaded{}}), do: false
  defp shared_flag(%{is_shared_to_workspace: v}) when is_boolean(v), do: v
  defp shared_flag(_), do: false

  defp file_icon(%{type: :image}), do: "lucide-image"
  defp file_icon(%{type: :video}), do: "lucide-film"
  defp file_icon(%{type: :text}), do: "lucide-file-text"
  defp file_icon(%{type: :email}), do: "lucide-mail"
  defp file_icon(%{mime_type: "application/pdf"}), do: "lucide-file-text"
  defp file_icon(_), do: "lucide-file"

  # ---------------------------------------------------------------------------
  # Filter / sort helpers (in-memory, after the DB query)
  # ---------------------------------------------------------------------------

  defp filter_by_q(items, ""), do: items

  defp filter_by_q(items, q) do
    Enum.filter(items, fn item ->
      String.contains?(String.downcase(item.name || ""), q)
    end)
  end

  defp sort_folders(items, "name:asc"), do: Enum.sort_by(items, &(&1.name || ""))
  defp sort_folders(items, "name:desc"), do: Enum.sort_by(items, &(&1.name || ""), :desc)

  defp sort_folders(items, _),
    do: Enum.sort_by(items, &(&1.updated_at || ~U[1970-01-01 00:00:00Z]), {:desc, DateTime})

  defp sort_files(items, "name:asc"), do: Enum.sort_by(items, &(&1.name || ""))
  defp sort_files(items, "name:desc"), do: Enum.sort_by(items, &(&1.name || ""), :desc)
  defp sort_files(items, "file_size:asc"), do: Enum.sort_by(items, &(&1.file_size || 0))
  defp sort_files(items, "file_size:desc"), do: Enum.sort_by(items, &(&1.file_size || 0), :desc)

  defp sort_files(items, "updated_at:asc"),
    do: Enum.sort_by(items, &(&1.updated_at || ~U[1970-01-01 00:00:00Z]), {:asc, DateTime})

  defp sort_files(items, _),
    do: Enum.sort_by(items, &(&1.updated_at || ~U[1970-01-01 00:00:00Z]), {:desc, DateTime})

  # ---------------------------------------------------------------------------
  # Breadcrumbs
  # ---------------------------------------------------------------------------

  defp breadcrumbs("my_files", _, _user), do: [%{label: gettext("My Files"), path: "/files"}]

  defp breadcrumbs("shared", _, _user),
    do: [%{label: gettext("Shared with me"), path: "/files?scope=shared"}]

  defp breadcrumbs("recent", _, _user),
    do: [%{label: gettext("Recent"), path: "/files?scope=recent"}]

  defp breadcrumbs("templates", _, _user),
    do: [%{label: gettext("Templates"), path: "/files?scope=templates"}]

  defp breadcrumbs("trash", _, _user),
    do: [%{label: gettext("Trash"), path: "/files?scope=trash"}]

  defp breadcrumbs("knowledge", coll, _user) when is_map(coll) do
    [
      %{label: gettext("Connected Sources"), path: "/files?scope=my_files"},
      %{label: coll.name || gettext("Collection"), path: "/files/knowledge/#{coll.id}"}
    ]
  end

  defp breadcrumbs("folder", folder, user) when is_map(folder) do
    chain = ancestor_chain(folder, user, [])
    root = %{label: gettext("My Files"), path: "/files"}

    crumbs =
      Enum.map(chain, fn f ->
        %{label: f.name || gettext("Untitled folder"), path: "/files/folder/#{f.id}"}
      end)

    [root | crumbs]
  end

  defp breadcrumbs(_, _, _user), do: []

  defp ancestor_chain(nil, _user, acc), do: acc
  defp ancestor_chain(%Magus.Chat.Folder{parent_id: nil} = f, _user, acc), do: [f | acc]

  defp ancestor_chain(%Magus.Chat.Folder{parent_id: pid} = f, user, acc) do
    case Magus.Chat.get_folder(pid, actor: user) do
      {:ok, parent} -> ancestor_chain(parent, user, [f | acc])
      _ -> [f | acc]
    end
  end
end
