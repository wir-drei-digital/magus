defmodule Magus.Agents.Actions.ConsolidateMemories do
  @moduledoc """
  Jido Action for periodic memory maintenance.

  This "Gardener" action performs daily maintenance on a user's memories:

  1. **Decay**: Deactivate memories that haven't been accessed in 90+ days
  2. **Promote**: Identify local memories that should become global (via PromoteMemoryCandidates)
  3. **Merge**: Cluster related memories into consolidated groups (via MergeMemories)
  4. **Distill**: Rewrite the Hermes-style user profile document per workspace
     bucket (via DistillUserProfile), gated by the user's `profile_enabled`
     setting

  ## Usage

      {:ok, result} = ConsolidateMemories.run(%{
        user_id: user.id
      }, %{})

      result.decayed_count   # => 5
      result.promoted_count  # => 2

  ## Scheduling

  This action is triggered by AshOban via the User resource:

      trigger :consolidate_memories do
        action :trigger_memory_consolidation
        queue :memory_consolidation
        scheduler_cron "0 3 * * *"  # 3 AM daily
        where expr(global_memory_enabled == true)
      end
  """

  use Jido.Action,
    name: "consolidate_memories",
    description: "Performs periodic memory maintenance",
    schema: [
      user_id: [type: :string, required: true, doc: "User ID to consolidate memories for"],
      stale_threshold_days: [
        type: :integer,
        default: 90,
        doc: "Days without access before memory is considered stale"
      ],
      skip_promotion: [
        type: :boolean,
        default: false,
        doc: "If true, skip the promotion step"
      ],
      skip_merge: [
        type: :boolean,
        default: false,
        doc: "If true, skip the merge step"
      ]
    ]

  require Logger
  require Ash.Query

  alias Magus.Agents.Support.AiAgent
  alias Magus.Agents.Actions.{MergeMemories, PromoteMemoryCandidates}
  alias Magus.Memory

  @actor %AiAgent{}

  @impl true
  def run(params, _context) do
    user_id = params[:user_id] || params["user_id"]
    stale_threshold_days = params[:stale_threshold_days] || params["stale_threshold_days"] || 90
    skip_promotion = params[:skip_promotion] || params["skip_promotion"] || false
    skip_merge = params[:skip_merge] || params["skip_merge"] || false

    workspace_filter =
      Map.get(params, :workspace_filter, Map.get(params, "workspace_filter", :all))

    # Validate required user_id
    if is_nil(user_id) or user_id == "" do
      Logger.error("ConsolidateMemories: user_id is required")
      {:error, "user_id is required"}
    else
      do_consolidation(
        user_id,
        stale_threshold_days,
        skip_promotion,
        skip_merge,
        workspace_filter
      )
    end
  end

  defp do_consolidation(
         user_id,
         stale_threshold_days,
         skip_promotion,
         skip_merge,
         workspace_filter
       ) do
    Logger.info("ConsolidateMemories: starting for user #{user_id}")

    # Step 1: Decay stale memories (workspace-agnostic; deactivation is per-row)
    decayed_count = decay_stale_memories(user_id, stale_threshold_days)
    Logger.info("ConsolidateMemories: decayed #{decayed_count} stale memories")

    # Determine workspace buckets for this user. Each bucket is processed in
    # isolation so promotion / merge never cross workspace boundaries.
    buckets =
      case workspace_filter do
        :all -> workspace_buckets_for(user_id)
        single -> [single]
      end

    # Step 2: Promote candidates per workspace bucket (unless skipped)
    promoted_count =
      if skip_promotion do
        0
      else
        Enum.reduce(buckets, 0, fn ws_id, acc ->
          case PromoteMemoryCandidates.run(
                 %{user_id: user_id, workspace_id: ws_id},
                 %{}
               ) do
            {:ok, %{promoted_count: count}} ->
              Logger.info(
                "ConsolidateMemories: promoted #{count} memories to user scope " <>
                  "(workspace #{inspect(ws_id)})"
              )

              acc + count

            {:error, error} ->
              Logger.warning(
                "ConsolidateMemories: promotion failed for workspace #{inspect(ws_id)}: " <>
                  inspect(error)
              )

              acc
          end
        end)
      end

    # Step 3: Merge related memories per workspace bucket (unless skipped)
    merged_count =
      if skip_merge do
        0
      else
        Enum.reduce(buckets, 0, fn ws_id, acc ->
          case MergeMemories.run(%{user_id: user_id, workspace_id: ws_id}, %{}) do
            {:ok, %{global_merged_count: gc, local_merged_count: lc}} ->
              Logger.info(
                "ConsolidateMemories: merged #{gc + lc} memory groups " <>
                  "(workspace #{inspect(ws_id)})"
              )

              acc + gc + lc

            _ ->
              acc
          end
        end)
      end

    # Step 4: Distill the Hermes-style user profile per workspace bucket,
    # gated by the user's profile_enabled setting. A failure for one bucket
    # logs and continues; decay/promote/merge results above are already
    # committed.
    profiles_distilled =
      if Magus.Agents.Config.profile_enabled?(to_string(user_id)) do
        distill_profiles(user_id, buckets)
      else
        0
      end

    {:ok,
     %{
       decayed_count: decayed_count,
       promoted_count: promoted_count,
       merged_count: merged_count,
       profiles_distilled: profiles_distilled,
       user_id: user_id,
       completed_at: DateTime.utc_now()
     }}
  end

  defp distill_profiles(user_id, buckets) do
    Enum.count(buckets, fn workspace_id ->
      case Magus.Agents.Actions.DistillUserProfile.run(
             %{
               user_id: to_string(user_id),
               workspace_id: workspace_id && to_string(workspace_id)
             },
             %{}
           ) do
        {:ok, _} ->
          true

        {:error, reason} ->
          Logger.warning(
            "ConsolidateMemories: profile distillation failed for bucket #{inspect(workspace_id)}: #{inspect(reason)}"
          )

          false
      end
    end)
  end

  # Returns distinct workspace_id values across the user's active memories.
  # Always includes at least nil (the personal-context bucket) so a user with
  # no memories yet still gets a single iteration.
  defp workspace_buckets_for(user_id) do
    case Memory.Memory
         |> Ash.Query.filter(user_id == ^user_id and is_active == true)
         |> Ash.Query.select([:workspace_id])
         |> Ash.read(authorize?: false) do
      {:ok, []} -> [nil]
      {:ok, rows} -> rows |> Enum.map(& &1.workspace_id) |> Enum.uniq()
      {:error, _} -> [nil]
    end
  end

  @doc """
  Decay (deactivate) memories that haven't been accessed in the threshold period.
  """
  def decay_stale_memories(user_id, threshold_days) do
    cutoff = DateTime.add(DateTime.utc_now(), -threshold_days, :day)

    # Find all stale memories for the user (not updated within threshold)
    case Memory.Memory
         |> Ash.Query.filter(
           user_id == ^user_id and
             is_active == true and
             fragment("COALESCE(last_accessed_at, updated_at)") < ^cutoff
         )
         |> Ash.read(actor: @actor) do
      {:ok, memories} ->
        memories
        |> Enum.reduce(0, fn memory, count ->
          case Memory.deactivate_memory(memory, actor: @actor) do
            {:ok, _} ->
              Logger.debug("ConsolidateMemories: deactivated stale memory '#{memory.name}'")
              count + 1

            {:error, error} ->
              Logger.warning(
                "ConsolidateMemories: failed to deactivate memory #{memory.id}: #{inspect(error)}"
              )

              count
          end
        end)

      {:error, error} ->
        Logger.error("ConsolidateMemories: failed to query stale memories: #{inspect(error)}")
        0
    end
  end
end
