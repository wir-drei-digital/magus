defmodule Magus.SuperBrain.Cleanup do
  @moduledoc """
  System-level cleanup hooks for the Super Brain pipeline.

  The Super Brain stores per-user state in two places:

    * Postgres: `SuperGraph`, `Episode`, and `ExtractionBudget` rows.
      `SuperGraph` and `ExtractionBudget` declare no foreign key to `users`
      (the writes happen as `:ai_agent` actors), so removing a user otherwise
      orphans that metadata. `Episode.source_user_id` DOES have a NO ACTION
      FK, so `AccountDeletion` clears it inside its own transaction too —
      this pass is best-effort and must not be the only thing standing
      between a user and their deletion.

    * FalkorDB: four personal graphs per user: `memories:user:<uid>`,
      `files:user:<uid>`, `drafts:user:<uid>`, and `super:user:<uid>`.
      These are also not referenced by any Postgres FK and grow without
      bound when a user is deleted.

  `purge_user/1` is invoked from `Magus.Accounts.AccountDeletion.execute/1`
  (the only sanctioned hard-delete path for a User row). It best-effort
  clears both stores. Failures here MUST NOT block the account deletion:
  the user has the right to be forgotten even if a downstream system is
  briefly unavailable. Anything that fails is logged for a follow-up
  janitor sweep.
  """

  require Ecto.Query
  require Logger

  @doc """
  Drop the four personal FalkorDB graphs for `user_id` and remove the
  corresponding Postgres bookkeeping rows (SuperGraph, Episode,
  ExtractionBudget).

  Always returns `:ok`. Individual failures are logged but never raise.
  """
  @spec purge_user(String.t()) :: :ok
  def purge_user(user_id) when is_binary(user_id) do
    drop_personal_graphs(user_id)
    delete_super_graph_rows(user_id)
    delete_episode_rows(user_id)
    delete_extraction_budget_rows(user_id)
    :ok
  end

  defp drop_personal_graphs(user_id) do
    for graph <- personal_graph_names(user_id) do
      # Anything other than a clean {:ok, _} is logged and skipped, including
      # raises: an unconfigured or unreachable FalkorDB must never propagate
      # out of purge_user/1 and abort the caller's account deletion.
      try do
        case Magus.Graph.drop(graph) do
          {:ok, _} ->
            :ok

          other ->
            Logger.warning("SuperBrain.Cleanup: drop graph #{graph} failed: #{inspect(other)}")

            :ok
        end
      rescue
        e ->
          Logger.warning(
            "SuperBrain.Cleanup: drop graph #{graph} crashed: #{Exception.message(e)}"
          )

          :ok
      end
    end

    :ok
  end

  defp personal_graph_names(user_id) do
    [
      "memories:user:#{user_id}",
      "files:user:#{user_id}",
      "drafts:user:#{user_id}",
      "super:user:#{user_id}"
    ]
  end

  # SuperGraph rows: one per (accessor_type, user_id, workspace_id). User
  # accessors point straight at user_id; workspace-scoped rows for this
  # user as the owner of the workspace are out of scope here (the
  # workspace itself owns those, and the workspace cleanup path is
  # responsible). We only purge rows where this user IS the accessor.
  defp delete_super_graph_rows(user_id) do
    delete_by_user_id(Magus.SuperBrain.SuperGraph, :user_id, user_id)
  end

  defp delete_episode_rows(user_id) do
    delete_by_user_id(Magus.SuperBrain.Episode, :source_user_id, user_id)
  end

  defp delete_extraction_budget_rows(user_id) do
    delete_by_user_id(Magus.SuperBrain.ExtractionBudget, :user_id, user_id)
  end

  # The three super_brain resources do not expose a `:destroy` Ash action.
  # Ash resources also implement the Ecto.Schema behaviour, so the module
  # name can be used as the Ecto schema directly with Repo.delete_all
  # (same pattern used by `Magus.Accounts.AccountDeletion`).
  defp delete_by_user_id(resource, column, user_id) do
    resource
    |> Ecto.Query.from(where: ^[{column, user_id}])
    |> Magus.Repo.delete_all()

    :ok
  rescue
    e ->
      Logger.warning(
        "SuperBrain.Cleanup: bulk delete on #{inspect(resource)} failed: #{Exception.message(e)} — orphan rows may remain"
      )

      :ok
  end
end
