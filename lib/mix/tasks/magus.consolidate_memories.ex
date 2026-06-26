defmodule Mix.Tasks.Magus.ConsolidateMemories do
  @moduledoc """
  Manually trigger memory consolidation for a user.

  Useful for development and testing of the consolidation pipeline
  (decay stale memories, promote local→global candidates).

  ## Usage

      mix magus.consolidate_memories <user_id>
      mix magus.consolidate_memories <user_id> --skip-promotion
      mix magus.consolidate_memories <user_id> --dry-run
      mix magus.consolidate_memories <user_id> --stale-days 30

  ## Options

      --skip-promotion  Skip the promotion step (only run decay)
      --dry-run         Show what would be promoted without actually doing it
      --stale-days N    Override the stale threshold (default: 90 days)

  ## Examples

      mix magus.consolidate_memories 123e4567-e89b-12d3-a456-426614174000
      mix magus.consolidate_memories 123e4567-e89b-12d3-a456-426614174000 --dry-run
      mix magus.consolidate_memories 123e4567-e89b-12d3-a456-426614174000 --stale-days 30
  """

  use Mix.Task

  require Logger

  @shortdoc "Trigger memory consolidation for a user"

  @switches [
    skip_promotion: :boolean,
    dry_run: :boolean,
    stale_days: :integer,
    workspace: :string
  ]

  @impl true
  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, switches: @switches)

    user_id =
      case rest do
        [id | _] -> id
        [] -> Mix.raise("Usage: mix magus.consolidate_memories <user_id> [options]")
      end

    Mix.Task.run("app.start")

    Mix.shell().info("Starting memory consolidation for user #{user_id}...")

    # Show current memory stats
    print_memory_stats(user_id)

    # Run consolidation directly (bypasses agent for simpler debugging)
    workspace_filter =
      case opts[:workspace] do
        nil -> :all
        "" -> :all
        "all" -> :all
        "null" -> nil
        "nil" -> nil
        id -> id
      end

    params = %{
      user_id: user_id,
      stale_threshold_days: opts[:stale_days] || 90,
      skip_promotion: opts[:skip_promotion] || false,
      workspace_filter: workspace_filter
    }

    if opts[:dry_run] do
      run_dry(user_id, params)
    else
      run_consolidation(params)
    end
  end

  defp run_consolidation(params) do
    case Magus.Agents.Actions.ConsolidateMemories.run(params, %{}) do
      {:ok, result} ->
        Mix.shell().info("""

        Consolidation complete:
          Decayed:  #{result.decayed_count} stale memories
          Promoted: #{result.promoted_count} memories to user scope
        """)

      {:error, error} ->
        Mix.shell().error("Consolidation failed: #{inspect(error)}")
    end
  end

  defp run_dry(user_id, params) do
    # Run decay check without applying
    stale_days = params.stale_threshold_days
    cutoff = DateTime.add(DateTime.utc_now(), -stale_days, :day)

    require Ash.Query

    stale =
      Magus.Memory.Memory
      |> Ash.Query.filter(
        user_id == ^user_id and
          is_active == true and
          updated_at < ^cutoff
      )
      |> Ash.read!(authorize?: false)

    Mix.shell().info("\n[DRY RUN] Would decay #{length(stale)} stale memories:")

    Enum.each(stale, fn m ->
      updated = Calendar.strftime(m.updated_at, "%Y-%m-%d")

      Mix.shell().info("  - #{m.name} (#{m.scope}, last updated: #{updated})")
    end)

    # Run promotion check
    unless params.skip_promotion do
      case Magus.Agents.Actions.PromoteMemoryCandidates.run(
             %{user_id: user_id, dry_run: true},
             %{}
           ) do
        {:ok, %{candidates: candidates, reasoning: reasoning}} ->
          Mix.shell().info("\n[DRY RUN] Would promote #{length(candidates)} memories:")

          Enum.each(candidates, fn c ->
            Mix.shell().info("  - #{c["memory_id"]}: #{c["reason"]}")
          end)

          if reasoning, do: Mix.shell().info("\nReasoning: #{reasoning}")

        {:ok, %{reason: reason}} ->
          Mix.shell().info("\n[DRY RUN] No promotions: #{reason}")

        {:error, error} ->
          Mix.shell().error("\nPromotion check failed: #{inspect(error)}")
      end
    end
  end

  defp print_memory_stats(user_id) do
    require Ash.Query

    all_memories =
      Magus.Memory.Memory
      |> Ash.Query.filter(user_id == ^user_id and is_active == true)
      |> Ash.read!(authorize?: false)

    local = Enum.count(all_memories, &(&1.scope == :local))
    user_scope = Enum.count(all_memories, &(&1.scope == :user))
    agent_scope = Enum.count(all_memories, &(&1.scope == :agent))
    with_embedding = Enum.count(all_memories, &(not is_nil(&1.summary_embedding)))

    conversations =
      all_memories
      |> Enum.map(& &1.conversation_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> length()

    Mix.shell().info("""

    Memory Stats for #{user_id}:
      Total active:      #{length(all_memories)}
      Local:             #{local} (across #{conversations} conversations)
      User-scope:        #{user_scope}
      Agent-scope:       #{agent_scope}
      With embeddings:   #{with_embedding}
    """)
  end
end
