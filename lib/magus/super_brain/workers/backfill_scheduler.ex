defmodule Magus.SuperBrain.Workers.BackfillScheduler do
  @moduledoc """
  Periodic Oban cron job. For each resource type the Super Brain knows
  how to extract (brain pages, memories, file chunks, drafts), this
  scheduler discovers resources that lack an `:extracted` `Episode` and
  enqueues their per-resource extraction worker.

  The scheduler is intentionally optimistic: it enqueues without
  consulting the per-user daily killswitch, since the per-resource
  workers themselves short-circuit on `ExtractionBudget.would_exceed_ceiling?/2`
  and return `{:cancel, :budget_exceeded}` when the user has saturated
  their daily limit. That means the rough draining math for a user with
  N pending resources is `min(per_user_cap, N)` enqueues per tick, with
  actual LLM-call work bounded by the daily budget.

  Per-resource-type per-user throttling: at most `@per_user_cap` (10)
  candidates per user per resource type per tick. With the default
  `*/15 * * * *` cron, that gives ~960 enqueues per user per resource
  type per day, well above the typical daily killswitch budget.

  Operators can drain a single user's backlog faster via the
  `mix super_brain.backfill --user <id>` task (Task 19), which bypasses
  the per-user cap but still honors the budget killswitch.

  ## Discovery query shape

  Candidate discovery uses a single SQL round trip per resource type
  via a `LEFT JOIN super_brain_episodes ... WHERE e.id IS NULL` so the
  database returns only rows that lack an `:extracted` Episode. This
  replaced an earlier implementation that fetched a 500-row candidate
  pool per type and then ran one Episode `read_one` per row, which
  scaled poorly past ~50 users (up to 2000 separate Episode SELECTs
  per 15-minute tick). The raw SQL bypasses Ash policies, which is
  fine because backfill discovery is always a system-level operation
  (the previous implementation also used `authorize?: false`); the
  rows leak only `id` and `user_id`, the same fields the Ash path
  exposed.
  """

  use Oban.Worker, queue: :super_brain_extraction, max_attempts: 1

  require Ash.Query
  require Logger

  @per_user_cap 10
  # Cap the SQL window so a runaway user doesn't pull millions of rows
  # per tick. Per-user grouping then narrows further to @per_user_cap.
  @candidate_pool_per_type 500

  # Back-off window: a resource whose most recent extraction attempt FAILED
  # within this window is skipped. Without it, a permanently-unextractable
  # resource (e.g. content the LLM can never return valid JSON for) never
  # earns an `:extracted` Episode, so the `e.id IS NULL` discovery picks it up
  # again every single tick and re-burns retries forever. The window lets it
  # retry periodically without churning the queue.
  @failed_backoff_interval "1 hour"

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    if Magus.SuperBrain.enabled?(),
      do: do_perform(job),
      else: {:cancel, :super_brain_disabled}
  end

  defp do_perform(%Oban.Job{args: _args}) do
    enqueue_brain_pages()
    enqueue_memories()
    enqueue_file_chunks()
    enqueue_drafts()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Brain pages
  # ---------------------------------------------------------------------------

  defp enqueue_brain_pages do
    sql = """
    SELECT p.id, b.user_id
      FROM brain_pages p
      JOIN brains b ON b.id = p.brain_id
      LEFT JOIN super_brain_episodes e
        ON e.resource_type = $1
       AND e.resource_id = p.id
       AND e.status = $2
      LEFT JOIN super_brain_episodes f
        ON f.resource_type = $1
       AND f.resource_id = p.id
       AND f.status = 'failed'
       AND f.updated_at > now() - interval '#{@failed_backoff_interval}'
     WHERE e.id IS NULL
       AND f.id IS NULL
       AND p.deleted_at IS NULL
     ORDER BY p.inserted_at DESC
     LIMIT $3
    """

    sql
    |> query_candidates(["brain_page", "extracted", @candidate_pool_per_type])
    |> cap_per_user()
    |> enqueue_each(Magus.SuperBrain.Workers.ExtractBrainPage, :brain_page)
  end

  # ---------------------------------------------------------------------------
  # Memories (only :user and :agent scopes; :local is excluded)
  # ---------------------------------------------------------------------------

  defp enqueue_memories do
    sql = """
    SELECT m.id, m.user_id
      FROM memories m
      LEFT JOIN super_brain_episodes e
        ON e.resource_type = $1
       AND e.resource_id = m.id
       AND e.status = $2
      LEFT JOIN super_brain_episodes f
        ON f.resource_type = $1
       AND f.resource_id = m.id
       AND f.status = 'failed'
       AND f.updated_at > now() - interval '#{@failed_backoff_interval}'
     WHERE e.id IS NULL
       AND f.id IS NULL
       AND m.scope IN ('user', 'agent')
     ORDER BY m.inserted_at DESC
     LIMIT $3
    """

    sql
    |> query_candidates(["memory", "extracted", @candidate_pool_per_type])
    |> cap_per_user()
    |> enqueue_each(Magus.SuperBrain.Workers.ExtractMemory, :memory)
  end

  # ---------------------------------------------------------------------------
  # File chunks (filter parent file type in [:document, :text, :email])
  # ---------------------------------------------------------------------------

  defp enqueue_file_chunks do
    sql = """
    SELECT c.id, f.user_id
      FROM file_chunks c
      JOIN files f ON f.id = c.file_id
      LEFT JOIN super_brain_episodes e
        ON e.resource_type = $1
       AND e.resource_id = c.id
       AND e.status = $2
      LEFT JOIN super_brain_episodes fe
        ON fe.resource_type = $1
       AND fe.resource_id = c.id
       AND fe.status = 'failed'
       AND fe.updated_at > now() - interval '#{@failed_backoff_interval}'
     WHERE e.id IS NULL
       AND fe.id IS NULL
       AND f.type IN ('document', 'text', 'email')
     ORDER BY c.inserted_at DESC
     LIMIT $3
    """

    sql
    |> query_candidates(["file_chunk", "extracted", @candidate_pool_per_type])
    |> cap_per_user()
    |> enqueue_each(Magus.SuperBrain.Workers.ExtractFileChunk, :file_chunk)
  end

  # ---------------------------------------------------------------------------
  # Drafts
  # ---------------------------------------------------------------------------

  defp enqueue_drafts do
    sql = """
    SELECT d.id, d.user_id
      FROM drafts d
      LEFT JOIN super_brain_episodes e
        ON e.resource_type = $1
       AND e.resource_id = d.id
       AND e.status = $2
      LEFT JOIN super_brain_episodes f
        ON f.resource_type = $1
       AND f.resource_id = d.id
       AND f.status = 'failed'
       AND f.updated_at > now() - interval '#{@failed_backoff_interval}'
     WHERE e.id IS NULL
       AND f.id IS NULL
       AND d.user_id IS NOT NULL
     ORDER BY d.inserted_at DESC
     LIMIT $3
    """

    sql
    |> query_candidates(["draft", "extracted", @candidate_pool_per_type])
    |> cap_per_user()
    |> enqueue_each(Magus.SuperBrain.Workers.ExtractDraft, :draft)
  end

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  # Executes a discovery query and returns a list of
  # `%{id: <string uuid>, user_id: <string uuid>}` maps.
  #
  # Raw rows come back as 16-byte binary UUIDs from Postgres; we cast
  # both columns back to string form so they round-trip cleanly through
  # Oban args (`%{"resource_id" => id}`) and the existing extractors,
  # which expect string IDs.
  defp query_candidates(sql, params) do
    case Magus.Repo.query(sql, params) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [id, user_id] ->
          %{id: Ecto.UUID.cast!(id), user_id: Ecto.UUID.cast!(user_id)}
        end)

      {:error, reason} ->
        Logger.error("BackfillScheduler discovery query failed: #{inspect(reason)}")
        []
    end
  end

  defp cap_per_user(candidates) do
    candidates
    |> Enum.group_by(& &1.user_id)
    |> Map.drop([nil])
    |> Enum.flat_map(fn {_uid, list} -> Enum.take(list, @per_user_cap) end)
  end

  defp enqueue_each(records, worker_module, resource_type) do
    Enum.each(records, fn %{id: id} ->
      %{"resource_id" => id}
      |> worker_module.new()
      |> Oban.insert()
    end)

    if records != [] do
      Logger.info("BackfillScheduler enqueued #{length(records)} #{resource_type} candidates")
    end

    :ok
  end
end
