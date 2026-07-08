defmodule Mix.Tasks.Magus.ConsolidateMemories do
  @moduledoc """
  Manually trigger memory consolidation for a user.

  Useful for development and testing of the profile distillation step: the
  nightly distiller is the sole ambient curator of user-level memory, gated
  by the user's `profile_enabled` setting.

  ## Usage

      mix magus.consolidate_memories <user_id>
      mix magus.consolidate_memories <user_id> --workspace <workspace_id>

  ## Options

      --workspace ID  Restrict to a single workspace bucket (default: all buckets)

  ## Examples

      mix magus.consolidate_memories 123e4567-e89b-12d3-a456-426614174000
      mix magus.consolidate_memories 123e4567-e89b-12d3-a456-426614174000 --workspace 89ab...
  """

  use Mix.Task

  require Logger

  @shortdoc "Trigger memory consolidation for a user"

  @switches [
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
      workspace_filter: workspace_filter
    }

    run_consolidation(params)
  end

  defp run_consolidation(params) do
    case Magus.Agents.Actions.ConsolidateMemories.run(params, %{}) do
      {:ok, result} ->
        Mix.shell().info("""

        Consolidation complete:
          Profiles distilled: #{result.profiles_distilled}
        """)

      {:error, error} ->
        Mix.shell().error("Consolidation failed: #{inspect(error)}")
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
