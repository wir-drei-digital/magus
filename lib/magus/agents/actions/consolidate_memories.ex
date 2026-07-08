defmodule Magus.Agents.Actions.ConsolidateMemories do
  @moduledoc """
  Jido Action for periodic memory maintenance.

  This "Gardener" action performs daily maintenance on a user's memories:

  1. **Distill**: Rewrite the Hermes-style user profile document per workspace
     bucket (via DistillUserProfile), gated by the user's `profile_enabled`
     setting

  The nightly distiller is the sole ambient curator of user-level memory.
  Repetition-based promotion and near-duplicate merging have been removed
  rather than tuned, and there is no time-based decay: no background process
  deletes or promotes memories. The per-conversation cap (enforced at
  extraction time) is the growth bound for local memories.

  ## Usage

      {:ok, result} = ConsolidateMemories.run(%{
        user_id: user.id
      }, %{})

      result.profiles_distilled  # => 1

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
      user_id: [type: :string, required: true, doc: "User ID to consolidate memories for"]
    ]

  require Logger
  require Ash.Query

  alias Magus.Memory

  @impl true
  def run(params, _context) do
    user_id = params[:user_id] || params["user_id"]

    workspace_filter =
      Map.get(params, :workspace_filter, Map.get(params, "workspace_filter", :all))

    # Validate required user_id
    if is_nil(user_id) or user_id == "" do
      Logger.error("ConsolidateMemories: user_id is required")
      {:error, "user_id is required"}
    else
      do_consolidation(user_id, workspace_filter)
    end
  end

  defp do_consolidation(user_id, workspace_filter) do
    Logger.info("ConsolidateMemories: starting for user #{user_id}")

    # Determine workspace buckets for this user. Each bucket is distilled in
    # isolation so profiles never cross workspace boundaries.
    buckets =
      case workspace_filter do
        :all -> workspace_buckets_for(user_id)
        single -> [single]
      end

    # Distill the Hermes-style user profile per workspace bucket, gated by
    # the user's profile_enabled setting. A failure for one bucket logs and
    # continues.
    profiles_distilled =
      if Magus.Agents.Config.profile_enabled?(to_string(user_id)) do
        distill_profiles(user_id, buckets)
      else
        0
      end

    {:ok,
     %{
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

  # Returns distinct workspace_id values across the user's memories. Always
  # includes at least nil (the personal-context bucket) so a user with no
  # memories yet still gets a single iteration.
  defp workspace_buckets_for(user_id) do
    case Memory.Memory
         |> Ash.Query.filter(user_id == ^user_id)
         |> Ash.Query.select([:workspace_id])
         |> Ash.read(authorize?: false) do
      {:ok, []} -> [nil]
      {:ok, rows} -> rows |> Enum.map(& &1.workspace_id) |> Enum.uniq()
      {:error, _} -> [nil]
    end
  end
end
