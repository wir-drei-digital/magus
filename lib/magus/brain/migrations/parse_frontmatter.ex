defmodule Magus.Brain.Migrations.ParseFrontmatter do
  @moduledoc """
  Phase B backfill worker: for each page with a non-null `body` and an
  empty `frontmatter` jsonb cache, parse the YAML frontmatter via
  `Magus.Brain.Frontmatter.parse/1` and populate the column.

  Runs after `BackfillPageBody` (depends on `body IS NOT NULL`).
  Idempotent: skips pages whose `frontmatter` is already non-empty (a
  later edit will repopulate via the Phase C save pipeline).

  Cron-scheduled every minute. Auto-disabling: zero work once every
  page with a body has been parsed.
  """

  use Oban.Worker,
    queue: :brain_backfill,
    max_attempts: 3

  import Ecto.Query
  require Logger

  alias Magus.Brain.Frontmatter
  alias Magus.Repo

  @batch_size 50

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: run_batch()

  @doc "See module doc; returns `{:ok, count}` with pages updated this tick."
  @spec run_batch(integer()) :: {:ok, non_neg_integer()}
  def run_batch(batch_size \\ @batch_size) do
    pages = pending_pages(batch_size)
    Enum.each(pages, &parse_one/1)
    {:ok, length(pages)}
  end

  defp pending_pages(limit) do
    from(p in "brain_pages",
      where: not is_nil(p.body),
      where: p.frontmatter == ^%{},
      where: is_nil(p.deleted_at),
      select: %{id: p.id, body: p.body},
      limit: ^limit,
      order_by: [asc: p.inserted_at]
    )
    |> Repo.all()
  end

  defp parse_one(%{id: page_id, body: body}) do
    case Frontmatter.parse(body) do
      {matter, _rest} when is_map(matter) and matter != %{} ->
        {1, _} =
          from(p in "brain_pages", where: p.id == ^page_id)
          |> Repo.update_all(set: [frontmatter: matter, updated_at: DateTime.utc_now()])

        :ok

      {%{}, _rest} ->
        # No frontmatter present; mark with an empty-but-truthy marker so we
        # don't re-process this row on every tick. Use a sentinel key so a
        # later frontmatter parse (Phase C save pipeline) can still
        # distinguish "never had any" from "had some, now removed".
        {1, _} =
          from(p in "brain_pages", where: p.id == ^page_id)
          |> Repo.update_all(
            set: [frontmatter: %{"_no_frontmatter" => true}, updated_at: DateTime.utc_now()]
          )

        :ok

      {:error, :invalid_frontmatter} ->
        # Malformed leading frontmatter — don't loop forever on it. Mark
        # with an error sentinel so an operator can spot-fix.
        Logger.warning(
          "ParseFrontmatter: malformed frontmatter on page #{pretty_id(page_id)}; flagging"
        )

        {1, _} =
          from(p in "brain_pages", where: p.id == ^page_id)
          |> Repo.update_all(
            set: [frontmatter: %{"_parse_error" => true}, updated_at: DateTime.utc_now()]
          )

        :ok
    end
  rescue
    e ->
      Logger.warning(
        "ParseFrontmatter: unexpected failure for page #{pretty_id(page_id)}: #{Exception.message(e)}"
      )

      :ok
  end

  defp pretty_id(<<_::128>> = bin), do: Ecto.UUID.load!(bin)
  defp pretty_id(other), do: inspect(other)
end
