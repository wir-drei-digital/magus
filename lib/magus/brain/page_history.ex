defmodule Magus.Brain.PageHistory do
  @moduledoc """
  Page-scoped version history for the brain page version viewer, sourced
  from `Magus.Brain.Page.Version` (AshPaperTrail snapshots, snapshot mode
  so each row carries the full post-edit `body`).

  Versions are read with `authorize?: false`, mirroring
  `Magus.Brain.Activity`: the caller (the LiveView) has already authorized
  the page by loading it for the actor, and we only ever read versions for
  that exact page id.
  """

  require Ash.Query

  alias Magus.Brain.Diff
  alias Magus.Brain.Page

  @default_limit 100
  @preview_chars 80

  # Safety cap for the whole-history reads (`version_diff/2`,
  # `version_body_for/2`). No single-version UI path needs more context than
  # this, and it bounds memory if a page accrues a huge edit history.
  @max_versions 1000

  @doc """
  Page versions newest first. Each entry:

      %{version_id, inserted_at, action_name, contributor_id, preview}
  """
  @spec list_for_page(binary(), keyword()) :: [map()]
  def list_for_page(page_id, opts \\ []) when is_binary(page_id) do
    limit = Keyword.get(opts, :limit, @default_limit)

    page_id
    |> versions_query()
    |> Ash.Query.limit(limit)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&to_entry/1)
  end

  @doc """
  Diff data for one version against the immediately older version of the
  same page. The oldest version diffs against an empty body. Returns
  `:error` when `version_id` does not belong to `page_id`.
  """
  @spec version_diff(binary(), binary()) :: {:ok, map()} | :error
  def version_diff(page_id, version_id)
      when is_binary(page_id) and is_binary(version_id) do
    versions = read_versions(page_id)

    case Enum.find_index(versions, &(&1.id == version_id)) do
      nil ->
        :error

      idx ->
        target = Enum.at(versions, idx)
        prior = Enum.at(versions, idx + 1)
        old_body = if prior, do: version_body(prior), else: ""

        {:ok,
         %{
           version_id: target.id,
           inserted_at: target.version_inserted_at,
           action_name: target.version_action_name,
           contributor_id: Map.get(target, :user_id),
           is_latest?: idx == 0,
           diff_rows: Diff.line_word_diff(old_body, version_body(target))
         }}
    end
  end

  @doc """
  The full snapshot body of one version. Used by restore. Returns `:error`
  when `version_id` does not belong to `page_id`.
  """
  @spec version_body_for(binary(), binary()) :: {:ok, binary()} | :error
  def version_body_for(page_id, version_id)
      when is_binary(page_id) and is_binary(version_id) do
    versions = read_versions(page_id)

    case Enum.find(versions, &(&1.id == version_id)) do
      nil -> :error
      version -> {:ok, version_body(version)}
    end
  end

  # uuid_v7 ids are time-ordered, so `id: :desc` is a stable tiebreaker when
  # two versions share a microsecond `version_inserted_at`. All version
  # actions are included so the history shows edits, renames, and moves;
  # snapshot mode stores the full body on every row, so diffing adjacent
  # versions always yields the true body delta (an empty diff for non-body
  # actions).
  defp versions_query(page_id) do
    Page.Version
    |> Ash.Query.filter(version_source_id == ^page_id)
    |> Ash.Query.sort(version_inserted_at: :desc, id: :desc)
  end

  # Whole-history read for the single-version lookups, capped so a page with
  # a huge edit history can't pull an unbounded result set into memory.
  defp read_versions(page_id) do
    page_id
    |> versions_query()
    |> Ash.Query.limit(@max_versions)
    |> Ash.read!(authorize?: false)
  end

  defp to_entry(version) do
    %{
      version_id: version.id,
      inserted_at: version.version_inserted_at,
      action_name: version.version_action_name,
      contributor_id: Map.get(version, :user_id),
      preview: preview_for(version)
    }
  end

  defp version_body(%{changes: changes}) when is_map(changes) do
    changes["body"] || changes[:body] || ""
  end

  defp version_body(_), do: ""

  defp preview_for(%{version_action_name: :update_body} = version) do
    case version_body(version) do
      bin when is_binary(bin) and bin != "" ->
        bin |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, @preview_chars)

      _ ->
        ""
    end
  end

  defp preview_for(_), do: ""
end
