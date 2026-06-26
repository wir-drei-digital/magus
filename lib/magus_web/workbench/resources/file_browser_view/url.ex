defmodule MagusWeb.Workbench.Resources.FileBrowserView.Url do
  @moduledoc """
  URL serialization helpers for file-browser tabs. Translates between the
  tab `primary` shape (`%{"type" => "file_browser", "scope" => ..., ...}`)
  and the canonical `/files/...` URLs the workbench uses.

  Used by WorkbenchLive when patching from sidebar interactions and by
  routing when reconstructing primary maps from URL params.
  """

  @spec build_primary(scope :: String.t(), id :: String.t() | nil, params :: map()) :: map()
  def build_primary(scope, id, params) do
    %{
      "type" => "file_browser",
      "scope" => scope,
      "id" => id,
      "filters" => %{
        "type" => Map.get(params, "type"),
        "modified" => Map.get(params, "modified"),
        "source" => Map.get(params, "source")
      },
      "sort" => Map.get(params, "sort", "updated_at:desc"),
      "q" => Map.get(params, "q", "")
    }
  end

  @spec base_path(primary :: map()) :: String.t()
  def base_path(primary) do
    case primary["scope"] do
      "folder" -> "/files/folder/#{primary["id"]}"
      "knowledge" -> "/files/knowledge/#{primary["id"]}"
      "my_files" -> "/files"
      scope -> "/files?scope=#{scope}"
    end
  end

  @spec url_params(primary :: map()) :: map()
  def url_params(primary) do
    %{
      "type" => primary["filters"]["type"],
      "modified" => primary["filters"]["modified"],
      "source" => primary["filters"]["source"],
      "sort" => if(primary["sort"] == "updated_at:desc", do: nil, else: primary["sort"]),
      "q" => if(primary["q"] in [nil, ""], do: nil, else: primary["q"])
    }
  end

  @spec append_query(base :: String.t(), query :: String.t()) :: String.t()
  def append_query(base, query) do
    sep = if String.contains?(base, "?"), do: "&", else: "?"
    base <> sep <> query
  end

  @spec drop_nil_or_empty(map()) :: map()
  def drop_nil_or_empty(map) do
    Map.new(Enum.reject(map, fn {_k, v} -> v in [nil, ""] end))
  end

  @doc """
  Builds the patch path used by the file-browser sidebar when only filter
  overrides need to change. Merges `overrides` over the current primary's
  url_params, drops empties, and re-encodes onto the existing base path.
  """
  @spec patch_path_for_overrides(primary :: map(), overrides :: map()) :: String.t()
  def patch_path_for_overrides(primary, overrides) do
    base = base_path(primary)

    query =
      primary
      |> url_params()
      |> Map.merge(overrides)
      |> drop_nil_or_empty()
      |> URI.encode_query()

    if query == "", do: base, else: append_query(base, query)
  end
end
