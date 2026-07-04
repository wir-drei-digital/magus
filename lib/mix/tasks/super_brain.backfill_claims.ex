defmodule Mix.Tasks.SuperBrain.BackfillClaims do
  @shortdoc "Re-extract a user's pre-claims content so it gains claims."

  @moduledoc """
      mix super_brain.backfill_claims --user <user_id|email> [--dry-run]

  Finds each resource whose latest `:extracted` Episode predates the
  claims-aware extractor version and force-re-extracts it (budget-gated,
  superseding the old episode via the normal `force: true` gate bypass -
  see `Magus.SuperBrain.Workers.ExtractBase`).

  Forward-only: only stale-version resources are touched. A resource whose
  latest Episode already matches the worker's current `extractor_version/0`
  is left alone, so re-running this task after a partial drain is safe and
  idempotent (it will only find what is still stale).

  `--dry-run` reports counts per resource type without enqueuing anything.
  """

  use Mix.Task

  require Ash.Query

  alias Magus.SuperBrain.Episode

  @workers %{
    brain_page: Magus.SuperBrain.Workers.ExtractBrainPage,
    brain_source: Magus.SuperBrain.Workers.ExtractBrainSource,
    memory: Magus.SuperBrain.Workers.ExtractMemory,
    file_chunk: Magus.SuperBrain.Workers.ExtractFileChunk,
    draft: Magus.SuperBrain.Workers.ExtractDraft
  }

  @impl Mix.Task
  def run(argv) do
    {opts, _argv, _errors} = OptionParser.parse(argv, strict: [user: :string, dry_run: :boolean])
    user_arg = Keyword.fetch!(opts, :user)
    dry? = Keyword.get(opts, :dry_run, false)

    Mix.Task.run("app.start")
    user_id = resolve_user_id(user_arg)

    Enum.each(@workers, fn {resource_type, worker} ->
      current = worker.extractor_version()
      stale = stale_episodes(user_id, resource_type, current)
      Mix.shell().info("#{resource_type}: #{length(stale)} stale (target #{current})")

      unless dry? do
        Enum.each(stale, fn episode ->
          %{"resource_id" => episode.resource_id, "force" => true}
          |> worker.new()
          |> Oban.insert!()
        end)
      end
    end)

    Mix.shell().info(if dry?, do: "Dry run: nothing enqueued.", else: "Enqueued.")
  end

  # Only the latest `:extracted` row per resource matters (D7 append-only
  # Episodes may have many `:superseded` rows for the same resource_id). A
  # resource whose latest Episode is nil (never extracted) or already
  # current is correctly excluded here - this task is forward-only, not a
  # general backfill of never-extracted content (that is
  # `mix super_brain.backfill`'s job).
  defp stale_episodes(user_id, resource_type, current_version) do
    Episode
    |> Ash.Query.filter(
      source_user_id == ^user_id and
        resource_type == ^resource_type and
        status == :extracted and
        extractor_version != ^current_version
    )
    |> Ash.read!(authorize?: false)
  end

  # Accept either a user id (UUID) or an email address so operators don't
  # have to look the UUID up first, mirroring `super_brain.backfill`'s
  # `resolve_user_id/1`.
  defp resolve_user_id(arg) do
    case Ecto.UUID.cast(arg) do
      {:ok, uuid} ->
        uuid

      :error ->
        case Magus.Accounts.get_by_email(arg, authorize?: false) do
          {:ok, %{id: id}} ->
            id

          _ ->
            Mix.raise(
              "No user found for --user #{inspect(arg)}. Pass a user id (UUID) or a registered email."
            )
        end
    end
  end
end
