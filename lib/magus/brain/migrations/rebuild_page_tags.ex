defmodule Magus.Brain.Migrations.RebuildPageTags do
  @moduledoc """
  Phase B backfill worker: rebuild `brain_page_tags` from two sources:

    * `frontmatter["tags"]` — list of strings, marked `source: :frontmatter`
    * inline `#tag` occurrences in the body, marked `source: :inline`

  When both produce the same tag for a page, the frontmatter row wins
  (frontmatter is the explicit declaration; inline is incidental).

  Idempotent + auto-disabling via the `frontmatter._tags_built_at`
  sentinel.
  """

  use Oban.Worker,
    queue: :brain_backfill,
    max_attempts: 3

  import Ecto.Query
  require Logger

  alias Magus.Brain.{BodyParser, Frontmatter}
  alias Magus.Repo

  @batch_size 50

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: run_batch()

  @spec run_batch(integer()) :: {:ok, non_neg_integer()}
  def run_batch(batch_size \\ @batch_size) do
    pages = pending_pages(batch_size)
    Enum.each(pages, &rebuild_one/1)
    {:ok, length(pages)}
  end

  defp pending_pages(limit) do
    from(p in "brain_pages",
      where: not is_nil(p.body),
      where: p.body != "",
      where: is_nil(p.deleted_at),
      where: fragment("? \\? '_tags_built_at'", p.frontmatter) == false,
      select: %{id: p.id, brain_id: p.brain_id, body: p.body, frontmatter: p.frontmatter},
      order_by: [asc: p.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp rebuild_one(page) do
    now = DateTime.utc_now()
    rows = build_tag_rows(page, now)

    Repo.transaction(fn ->
      from(t in "brain_page_tags", where: t.page_id == ^page.id) |> Repo.delete_all()

      if rows != [] do
        Repo.insert_all("brain_page_tags", rows, on_conflict: :nothing)
      end

      # Only sentinel if ParseFrontmatter has already touched this page. If
      # frontmatter is still %{} (the column default), the frontmatter tags
      # list is missing from the rebuild — we'd permanently lock-out a page
      # whose frontmatter cache hasn't been populated yet. ParseFrontmatter
      # sets one of `_no_frontmatter`, `_parse_error`, or the parsed map; in
      # all three cases the cache is stable and we can sentinel.
      if frontmatter_cache_ready?(page.frontmatter) do
        mark_built(page.id, page.frontmatter, now)
      else
        Logger.debug(
          "RebuildPageTags: page #{inspect(page.id)} frontmatter cache not ready; not setting sentinel"
        )
      end
    end)

    :ok
  rescue
    e ->
      Logger.warning(
        "RebuildPageTags: failed for page #{inspect(page.id)}: #{Exception.message(e)}"
      )

      :ok
  end

  defp frontmatter_cache_ready?(%{} = fm) when map_size(fm) > 0, do: true
  defp frontmatter_cache_ready?(_), do: false

  defp build_tag_rows(page, now) do
    frontmatter_tags =
      (page.frontmatter || %{})
      |> Map.get("tags", [])
      |> List.wrap()
      |> Enum.map(&Frontmatter.normalize_tag(to_string(&1)))
      |> Enum.reject(&(&1 == ""))

    inline_tags = BodyParser.inline_tags(page.body)

    # Frontmatter wins when both sources produce the same tag.
    inline_only = Enum.reject(inline_tags, &(&1 in frontmatter_tags))

    frontmatter_rows = Enum.map(frontmatter_tags, &row(&1, :frontmatter, page, now))
    inline_rows = Enum.map(inline_only, &row(&1, :inline, page, now))

    frontmatter_rows ++ inline_rows
  end

  defp row(tag, source, page, now) do
    %{
      id: new_uuid_bin(),
      tag: tag,
      source: Atom.to_string(source),
      page_id: page.id,
      brain_id: page.brain_id,
      inserted_at: now
    }
  end

  defp mark_built(page_id, frontmatter, now) do
    updated = Map.put(frontmatter || %{}, "_tags_built_at", DateTime.to_iso8601(now))

    {1, _} =
      from(p in "brain_pages", where: p.id == ^page_id)
      |> Repo.update_all(set: [frontmatter: updated, updated_at: now])

    :ok
  end

  defp new_uuid_bin do
    case Ecto.UUID.dump(Ash.UUIDv7.generate()) do
      {:ok, bin} -> bin
      :error -> raise "failed to dump UUID"
    end
  end
end
