defmodule Magus.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  require Logger

  @app :magus

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  def seed do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          seeds_file = Application.app_dir(@app, "priv/repo/seeds.exs")

          if File.exists?(seeds_file) do
            Code.eval_file(seeds_file)
          end
        end)
    end
  end

  @doc """
  Production-safe wrapper around the billing edition's Stripe provisioning
  (`mix magus.stripe.*`, unavailable in a release since Mix isn't shipped).

  Delegates to `Magus.Billing.Release.provision_stripe/0` (override via
  `:magus, :billing_release_module`), dispatched dynamically so a pure OSS core
  compiles and boots without `Magus.Billing`. An install without the billing
  edition returns `{:error, :billing_edition_not_present}`.

  Invoke from a release on the running node with:

      bin/magus rpc "Magus.Release.provision_stripe()"

  Use `rpc`, NOT `eval`: see `brain_migrate/0` for why (eval boots a second BEAM
  with Oban cron and can deadlock the live node). `rpc` runs on the already-booted
  node, so the Repo, runtime config (the Stripe key), and Ash are all up.
  """
  def provision_stripe do
    case billing_release_module() do
      nil -> {:error, :billing_edition_not_present}
      mod -> mod.provision_stripe()
    end
  end

  defp billing_release_module do
    mod = Application.get_env(@app, :billing_release_module, Magus.Billing.Release)

    if Code.ensure_loaded?(mod) and function_exported?(mod, :provision_stripe, 0),
      do: mod,
      else: nil
  end

  @doc """
  Production-safe wrapper around `mix magus.brain.migrate`. Runs every
  Phase B backfill step (body → frontmatter → sources → chunks →
  rebuilds) until each reports zero pending. Idempotent; safe to re-run.

  Invoke from a release on the running node with:

      bin/magus rpc "Magus.Release.brain_migrate()"

  Use `rpc`, NOT `eval`: `eval` starts a SECOND BEAM that boots the full
  app, including Oban with its cron schedulers, which then competes with
  the running prod node for cron-lock claims and DB connections. The two
  nodes can deadlock waiting on the same advisory locks. `rpc` runs the
  function on the already-booted prod node so there's no contention.

  Logger output goes to the prod node's log stream (visible via
  `bin/magus log` or your container log driver).
  """
  def brain_migrate do
    steps = [
      {Magus.Brain.Migrations.BackfillPageBody, "page bodies"},
      {Magus.Brain.Migrations.ParseFrontmatter, "frontmatter"},
      {Magus.Brain.Migrations.BackfillSources, "sources"},
      {Magus.Brain.Migrations.BackfillPageChunks, "page chunks"},
      {Magus.Brain.Migrations.BackfillSourceChunks, "source chunks"},
      {Magus.Brain.Migrations.RebuildPageLinks, "page links"},
      {Magus.Brain.Migrations.RebuildPageSources, "page sources"},
      {Magus.Brain.Migrations.RebuildPageTags, "page tags"}
    ]

    Logger.info("[brain_migrate] start")

    Enum.each(steps, fn {worker, label} ->
      total = drain(worker, 0)
      Logger.info("[brain_migrate] #{label}: #{total} processed")
    end)

    Logger.info("[brain_migrate] done — run Magus.Release.brain_audit/0 to verify")
    flush_logger()
    :ok
  end

  @doc """
  Production-safe wrapper around `mix magus.brain.backfill_audit`. Counts
  pages whose body was never backfilled and pages whose body is non-empty
  but has no chunks. Re-renders blocks for every page and compares to the
  stored body to catch any divergence. Halts the node with status 1 on
  failure so it can be used as a deploy gate.

  Invoke from a release on the running node with:

      bin/magus rpc "Magus.Release.brain_audit()"

  See `brain_migrate/0` for why `rpc` is preferred over `eval`.
  """
  def brain_audit do
    run_audit()
  end

  defp run_audit do
    import Ecto.Query
    require Ash.Query

    alias Magus.Brain.BlockSerializer
    alias Magus.Brain.BodyParser
    alias Magus.Repo

    body_incomplete =
      Repo.one(
        from p in "brain_pages",
          where: is_nil(p.deleted_at),
          where: is_nil(p.body),
          select: count(p.id)
      )

    chunk_gaps =
      Repo.one(
        from p in "brain_pages",
          left_join: c in "brain_page_chunks",
          on: c.page_id == p.id,
          where: is_nil(p.deleted_at),
          where: not is_nil(p.body),
          where: fragment("length(?)", p.body) > 50,
          where: is_nil(c.id),
          select: count(p.id, :distinct)
      )

    pages =
      Repo.all(
        from p in "brain_pages",
          where: is_nil(p.deleted_at),
          select: %{id: p.id, body: p.body}
      )

    {body_div, source_mm, link_mm} =
      Enum.reduce(pages, {[], [], []}, fn page, {bd, sm, lm} ->
        result = audit_one(page, BlockSerializer, BodyParser, Repo)
        {bd ++ result.body, sm ++ result.sources, lm ++ result.links}
      end)

    Logger.info("[brain_audit] body never backfilled (NULL, non-trashed): #{body_incomplete}")
    Logger.info("[brain_audit] chunk gaps (body > 50 chars, no chunks): #{chunk_gaps}")
    Logger.info("[brain_audit] pages render-compared: #{length(pages)}")

    # Divergences (body vs re-render-from-blocks, body source-URLs vs
    # brain_page_sources, body wikilinks vs brain_page_links) are EXPECTED
    # once users start editing pages via the editor — the body diverges
    # from the legacy block tree by design after cutover. They're
    # informational here, not deploy-gating. The hard-fail signals are
    # "page never got a body" and "page has body but no chunks at all".
    Logger.info("[brain_audit] body divergences (informational): #{length(body_div)}")
    Logger.info("[brain_audit] source ref mismatches (informational): #{length(source_mm)}")
    Logger.info("[brain_audit] wikilink mismatches (informational): #{length(link_mm)}")

    failed? = body_incomplete > 0 or chunk_gaps > 0

    if failed? do
      Logger.error(
        "[brain_audit] AUDIT FAILED — investigate. Re-run Magus.Release.brain_migrate/0 if needed."
      )

      # Logger is async; flush before halting so the operator sees the
      # failure summary instead of a silent exit.
      flush_logger()
      System.halt(1)
    else
      Logger.info("[brain_audit] AUDIT PASSED")
      flush_logger()
      :ok
    end
  end

  # The standard Logger has no public flush. Sleep briefly so any queued
  # handler messages reach stdout before we return / halt. 200ms is
  # generous enough for a few dozen log lines on any reasonable handler.
  defp flush_logger, do: Process.sleep(200)

  defp audit_one(%{id: id_bin, body: current_body}, block_serializer, body_parser, repo) do
    require Ash.Query
    import Ecto.Query

    rendered =
      Magus.Brain.Block
      |> Ash.Query.filter(page_id == ^Ecto.UUID.load!(id_bin))
      |> Ash.Query.sort(position: :asc)
      |> Ash.read!(authorize?: false)
      |> block_serializer.to_markdown()

    pretty_id = Ecto.UUID.load!(id_bin)

    body_div =
      if rendered != (current_body || ""),
        do: [
          "#{pretty_id}: body length #{byte_size(current_body || "")} vs rendered #{byte_size(rendered)}"
        ],
        else: []

    expected_sources = body_parser.source_urls(current_body) |> length()

    actual_sources =
      repo.one(
        from s in "brain_page_sources",
          where: s.page_id == ^id_bin,
          select: count(s.id)
      )

    source_mm =
      if expected_sources > 0 and actual_sources != expected_sources,
        do: ["#{pretty_id}: #{expected_sources} URLs in body vs #{actual_sources} rows"],
        else: []

    expected_links = body_parser.wikilinks(current_body) |> length()

    actual_links =
      repo.one(
        from l in "brain_page_links",
          where: l.source_page_id == ^id_bin,
          select: count(l.id)
      )

    link_mm =
      if actual_links > expected_links,
        do: ["#{pretty_id}: #{actual_links} link rows vs #{expected_links} wikilinks in body"],
        else: []

    %{body: body_div, sources: source_mm, links: link_mm}
  end

  defp drain(worker, acc) do
    case worker.run_batch() do
      {:ok, 0} -> acc
      {:ok, n} -> drain(worker, acc + n)
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
