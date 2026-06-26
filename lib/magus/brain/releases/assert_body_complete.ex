defmodule Magus.Brain.Releases.AssertBodyComplete do
  @moduledoc """
  Release-time gate. Raises if any non-trashed page has `body IS NULL OR
  body = ''`. Intended to be called from the deploy pipeline BEFORE Phase C
  cutover ships, after `mix magus.brain.force_resync` has been run to catch
  up any pages the cron missed.

  In a production release (no Mix):

      bin/magus eval "Magus.Brain.Releases.AssertBodyComplete.run()"

  Returns `:ok` on success; raises `RuntimeError` on any incomplete pages.
  The exception message includes the count plus the first 10 offending
  page IDs so operators can spot-check.
  """

  import Ecto.Query

  alias Magus.Repo

  @doc """
  Asserts all non-trashed pages have non-empty body. Raises otherwise.
  """
  @spec run() :: :ok | no_return()
  def run do
    incomplete = sample_incomplete()
    count = count_incomplete()

    if count == 0 do
      :ok
    else
      raise RuntimeError, """
      Magus.Brain.Releases.AssertBodyComplete: #{count} non-trashed page(s) have empty body.

      Phase C cannot deploy until every page has body populated. Run
      `mix magus.brain.force_resync` (or `bin/magus eval Mix.Tasks.Magus.Brain.ForceResync.run([])`
      in a release) and re-run this gate.

      First incomplete page IDs (up to 10):
      #{Enum.map_join(incomplete, "\n", &"  - #{&1}")}
      """
    end
  end

  defp count_incomplete do
    Repo.one(
      from(p in "brain_pages",
        where: is_nil(p.deleted_at),
        where: is_nil(p.body) or p.body == "",
        select: count(p.id)
      )
    )
  end

  defp sample_incomplete do
    Repo.all(
      from(p in "brain_pages",
        where: is_nil(p.deleted_at),
        where: is_nil(p.body) or p.body == "",
        select: p.id,
        limit: 10
      )
    )
    |> Enum.map(&Ecto.UUID.load!/1)
  end
end
