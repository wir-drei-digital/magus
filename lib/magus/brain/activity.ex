defmodule Magus.Brain.Activity do
  @moduledoc """
  Per-brain activity feed sourced from `Magus.Brain.Page.Version` rows
  (the AshPaperTrail snapshot of every page mutation).

  Versions are loaded with `authorize?: false` because `Page.Version`'s
  default policy forbids user-facing reads (see
  `Magus.Brain.PageVersionPolicyTest`). The brain ownership check is
  applied upstream by the LiveView: it can only render the feed for a
  brain the actor already loaded.
  """

  require Ash.Query

  alias Magus.Brain
  alias Magus.Brain.Page

  @default_limit 50
  @preview_chars 80

  @doc """
  Returns the latest activity entries for the given brain, newest first.

  Options:
    * `:limit` (integer, default 50) — caps the number of versions read.

  Each entry is a map:

      %{
        version_id:      uuid,
        page_id:         uuid,
        page_title:      binary,
        contributor_id:  uuid | nil,
        contributor_type: :user,
        inserted_at:     DateTime.t(),
        action_name:     atom,
        preview:         binary
      }

  `:preview` is the first #{@preview_chars} characters of the new body
  for `:update_body` actions; for other actions it's an empty string
  (we'd otherwise leak titles/slug renames as fake "body" snippets).
  """
  @spec list_brain_activity(String.t(), keyword()) :: [map()]
  def list_brain_activity(brain_id, opts \\ []) when is_binary(brain_id) do
    limit = Keyword.get(opts, :limit, @default_limit)

    case page_ids_for_brain(brain_id) do
      [] ->
        []

      page_ids ->
        page_title_index = page_title_index(page_ids)

        Page.Version
        |> Ash.Query.filter(version_source_id in ^page_ids)
        |> Ash.Query.sort(version_inserted_at: :desc)
        |> Ash.Query.limit(limit)
        |> Ash.read!(authorize?: false)
        |> Enum.map(&version_to_activity_entry(&1, page_title_index))
    end
  end

  defp page_ids_for_brain(brain_id) do
    case Brain.list_pages(brain_id, authorize?: false) do
      {:ok, pages} -> Enum.map(pages, & &1.id)
      _ -> []
    end
  end

  defp page_title_index(page_ids) do
    Page
    |> Ash.Query.filter(id in ^page_ids)
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.id, &1.title})
  end

  defp version_to_activity_entry(version, page_title_index) do
    page_id = version.version_source_id

    %{
      version_id: version.id,
      page_id: page_id,
      page_title: Map.get(page_title_index, page_id) || "Untitled",
      contributor_id: Map.get(version, :user_id),
      contributor_type: :user,
      inserted_at: version.version_inserted_at,
      action_name: version.version_action_name,
      preview: preview_for(version)
    }
  end

  defp preview_for(%{version_action_name: :update_body, changes: changes})
       when is_map(changes) do
    body = changes["body"] || changes[:body]

    case body do
      bin when is_binary(bin) ->
        bin
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> String.slice(0, @preview_chars)

      _ ->
        ""
    end
  end

  defp preview_for(_), do: ""
end
