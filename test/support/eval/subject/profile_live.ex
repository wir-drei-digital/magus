defmodule Magus.Eval.Subject.ProfileLive do
  @moduledoc """
  Subject for the profile_distill benchmark. Creates a fresh user per case,
  seeds the encoded user-scope memories (backdating updated_at so recency
  ordering is meaningful), runs the real DistillUserProfile action, and
  returns the document. Lives in test support because it depends on
  Magus.Generators.
  """
  @behaviour Magus.Eval.Subject

  alias Magus.Agents.Support.AiAgent

  @actor %AiAgent{}

  @impl true
  def reset(ctx) do
    user = Magus.Generators.generate(Magus.Generators.user())
    {:ok, Map.put(ctx, :profile_user, user)}
  end

  @impl true
  def ingest(ctx, items) do
    Enum.each(items, fn %{text: json} ->
      seed = Jason.decode!(json)

      {:ok, memory} =
        Magus.Memory.create_user_memory(
          ctx.profile_user.id,
          nil,
          seed["name"],
          %{content: seed["content"] || %{}, summary: seed["summary"]},
          actor: @actor
        )

      backdate(memory, seed["updated_at_days_ago"])
    end)

    {:ok, ctx}
  end

  @impl true
  def query(ctx, _question) do
    case Magus.Agents.Actions.DistillUserProfile.run(
           %{user_id: to_string(ctx.profile_user.id), workspace_id: nil},
           %{}
         ) do
      {:ok, %{document: document, token_estimate: token_estimate}} ->
        {:ok, %{answer: document, meta: %{token_estimate: token_estimate}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Raw SQL: updated_at is not writable through actions, and the distiller
  # prompt orders memories by it.
  defp backdate(_memory, nil), do: :ok

  defp backdate(memory, days_ago) do
    ts = DateTime.add(DateTime.utc_now(), -days_ago * 86_400, :second)
    {:ok, uuid} = Ecto.UUID.dump(to_string(memory.id))

    Magus.Repo.query!("UPDATE memories SET updated_at = $1 WHERE id = $2", [ts, uuid])
    :ok
  end
end
