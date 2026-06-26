defmodule Magus.Agents.Tools.SuperBrain.PinFact do
  @moduledoc """
  Pin a high-confidence fact between two brain pages.

  Enqueues `Magus.SuperBrain.Workers.IngestBrainPin`, which writes the edge
  into the brain's FalkorDB graph at `:instruction` trust tier (1.5x
  ranking multiplier). Both pages are access-checked with the calling
  user as actor before the pin is enqueued; an inaccessible page returns
  an error and enqueues nothing.

  Iter4 Task 4: this is the third pathway that lights up `:instruction`
  tier from real signal (alongside important callouts and explicit memory
  kinds). Before iter4 the multiplier was unreachable for every
  LLM-extracted canonical, so trust tier contributed nothing to ranking.
  """

  use Jido.Action,
    name: "pin_fact",
    description: """
    Mark a high-confidence relationship between two brain pages as
    "remember this hard". The resulting edge enters the super brain at
    instruction trust tier (1.5x ranking boost) so retrieval prefers it
    over ordinary LLM-extracted facts.

    Use this when the user explicitly says "remember that X relates to Y"
    or when you want the graph to prioritize a stable, user-confirmed
    relationship.
    """,
    schema: [
      source_page_id: [
        type: :string,
        required: true,
        doc: "Source brain page UUID"
      ],
      target_page_id: [
        type: :string,
        required: true,
        doc: "Target brain page UUID"
      ],
      predicate: [
        type: {:in, ["supports", "contradicts", "relates_to", "derived_from"]},
        default: "relates_to",
        doc: "Edge predicate"
      ]
    ]

  @doc "User-facing display name shown while the tool is running."
  def display_name, do: "Pinning fact..."

  @doc "Human-readable output summary for UI display."
  def summarize_output(%{ok: true}), do: "Pinned"
  def summarize_output(%{error: e}) when is_binary(e), do: "Error: #{e}"
  def summarize_output(%{error: e}), do: "Error: #{inspect(e)}"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(%{source_page_id: sid, target_page_id: tid, predicate: pred}, ctx) do
    if Magus.SuperBrain.enabled?() do
      with {:ok, user_id} <- fetch_user_id(ctx),
           {:ok, user} <- Magus.Accounts.get_user(user_id, authorize?: false),
           {:ok, source} <- Magus.Brain.get_page(sid, actor: user),
           {:ok, target} <- Magus.Brain.get_page(tid, actor: user),
           :ok <- same_brain(source, target),
           {:ok, _job} <- enqueue_pin(sid, tid, pred, user_id) do
        {:ok, %{ok: true}}
      else
        {:error, reason} -> {:ok, %{error: format_error(reason)}}
      end
    else
      {:ok, %{error: "the Super Brain is disabled"}}
    end
  end

  defp fetch_user_id(%{user_id: uid}) when is_binary(uid), do: {:ok, uid}
  defp fetch_user_id(_), do: {:error, :missing_user_id}

  defp same_brain(%{brain_id: b}, %{brain_id: b}), do: :ok
  defp same_brain(_, _), do: {:error, :pages_in_different_brains}

  defp enqueue_pin(source_page_id, target_page_id, predicate, user_id) do
    %{
      "source_page_id" => source_page_id,
      "target_page_id" => target_page_id,
      "predicate" => predicate,
      "user_id" => user_id
    }
    |> Magus.SuperBrain.Workers.IngestBrainPin.new()
    |> Oban.insert()
  end

  defp format_error(:pages_in_different_brains),
    do: "source and target pages must be in the same brain"

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
