defmodule Magus.Models.ModelReferences do
  @moduledoc """
  Counts rows referencing a model, for lifecycle UI (deactivate/delete
  guidance). FKs have no ON DELETE action, so Postgres already restricts
  deletes; these counts explain *why* to the admin.

  Only the three categories most actionable for an admin are surfaced:
  conversations (user-facing model selections), routing slots (auto-router
  config), and role assignments (internal role overrides). Several other
  tables also carry restricting FKs to `models` (e.g. `users`,
  `custom_agents`, `personas`, `prompts`, `messages`, `sessions`,
  `conversation_contexts`); these are intentionally not counted here because
  they are either historical records or rarely the actionable blocker. The
  only nilify-on-delete FK is `message_usages.model_id`. If delete-guidance
  needs to enumerate every blocker, extend `counts/1` with those categories.
  """

  import Ecto.Query
  alias Magus.Repo

  @spec counts(Ecto.UUID.t()) :: %{
          conversations: non_neg_integer(),
          routing_slots: non_neg_integer(),
          role_assignments: non_neg_integer()
        }
  def counts(model_id) do
    %{
      conversations:
        Repo.one(
          from c in "conversations",
            where:
              c.selected_model_id == type(^model_id, :binary_id) or
                c.selected_image_model_id == type(^model_id, :binary_id) or
                c.selected_video_model_id == type(^model_id, :binary_id),
            select: count(c.id)
        ),
      routing_slots:
        Repo.one(
          from r in "routing_slots",
            where: r.model_id == type(^model_id, :binary_id),
            select: count(r.id)
        ),
      role_assignments:
        Repo.one(
          from a in "model_role_assignments",
            where: a.model_id == type(^model_id, :binary_id),
            select: count(a.id)
        )
    }
  end

  @spec total(Ecto.UUID.t()) :: non_neg_integer()
  def total(model_id), do: counts(model_id) |> Map.values() |> Enum.sum()
end
