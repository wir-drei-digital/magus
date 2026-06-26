defmodule Mix.Tasks.SuperBrain.Backfill do
  @shortdoc "Force-backfill super brain extraction for a specific user."

  @moduledoc """
  Drains pending extraction for one user, ignoring the per-user-per-tick cap
  that the BackfillScheduler enforces. Respects the daily budget killswitch.

      mix super_brain.backfill --user <user_id|email> --resource-type brain_page
      mix super_brain.backfill --user <user_id|email>          # all resource types

  Resource types: `brain_page` | `memory` | `file_chunk` | `draft`

  Useful during rollout to prioritize a specific user. Honors the user's
  `super_brain_extraction_budget.ceiling_call_count` field via the per-resource
  worker short-circuit on `ExtractionBudget.would_exceed_ceiling?/2`. If a user
  has 5000 candidates, this task enqueues all 5000 jobs but only ~100 succeed
  per day. Subsequent days drain the rest as the queue is re-processed.
  """

  use Mix.Task

  require Ash.Query

  @extractable_file_types [:document, :text, :email]

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args, strict: [user: :string, resource_type: :string])

    user_arg = Keyword.fetch!(opts, :user)
    resource_type = Keyword.get(opts, :resource_type)

    Mix.Task.run("app.start")

    user_id = resolve_user_id(user_arg)

    types =
      case resource_type do
        nil -> [:brain_page, :memory, :file_chunk, :draft]
        rt -> [parse_type(rt)]
      end

    Enum.each(types, fn type ->
      Mix.shell().info("Draining #{type} for user #{user_id}...")
      drain(user_id, type)
    end)

    Mix.shell().info("Done.")
  end

  defp parse_type("brain_page"), do: :brain_page
  defp parse_type("memory"), do: :memory
  defp parse_type("file_chunk"), do: :file_chunk
  defp parse_type("draft"), do: :draft
  defp parse_type(other), do: Mix.raise("Unknown --resource-type: #{other}")

  # Accept either a user id (UUID) or an email address so operators don't have
  # to look the UUID up first. A non-UUID is resolved via the email lookup; a
  # bad value raises instead of silently matching nothing (the `:memory` /
  # `:draft` drains filter `user_id` in Postgres, so an email there used to
  # crash on the UUID cast, while `:brain_page` / `:file_chunk` filter in
  # memory and silently enqueued 0 jobs).
  defp resolve_user_id(arg) do
    case Ecto.UUID.cast(arg) do
      {:ok, uuid} ->
        uuid

      :error ->
        case Magus.Accounts.get_by_email(arg, authorize?: false) do
          {:ok, %{id: id}} ->
            Mix.shell().info("Resolved #{arg} to user #{id}")
            id

          _ ->
            Mix.raise(
              "No user found for --user #{inspect(arg)}. Pass a user id (UUID) or a registered email."
            )
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Brain pages: user lives on the parent brain
  # ---------------------------------------------------------------------------

  defp drain(user_id, :brain_page) do
    pages =
      Magus.Brain.Page
      |> Ash.Query.filter(is_nil(deleted_at))
      |> Ash.Query.load(:brain)
      |> Ash.read!(authorize?: false)
      |> Enum.filter(fn p -> p.brain && p.brain.user_id == user_id end)

    enqueue_all(pages, Magus.SuperBrain.Workers.ExtractBrainPage)
  end

  # ---------------------------------------------------------------------------
  # Memories: direct user_id; only :user and :agent scopes are extractable
  # ---------------------------------------------------------------------------

  defp drain(user_id, :memory) do
    memories =
      Magus.Memory.Memory
      |> Ash.Query.filter(user_id == ^user_id and scope in [:user, :agent])
      |> Ash.read!(authorize?: false)

    enqueue_all(memories, Magus.SuperBrain.Workers.ExtractMemory)
  end

  # ---------------------------------------------------------------------------
  # File chunks: user lives on the parent file; only extractable types
  # ---------------------------------------------------------------------------

  defp drain(user_id, :file_chunk) do
    chunks =
      Magus.Files.Chunk
      |> Ash.Query.load(:file)
      |> Ash.read!(authorize?: false)
      |> Enum.filter(fn c ->
        (c.file && c.file.user_id == user_id) and
          c.file.type in @extractable_file_types
      end)

    enqueue_all(chunks, Magus.SuperBrain.Workers.ExtractFileChunk)
  end

  # ---------------------------------------------------------------------------
  # Drafts: direct user_id
  # ---------------------------------------------------------------------------

  defp drain(user_id, :draft) do
    drafts =
      Magus.Drafts.Draft
      |> Ash.Query.filter(user_id == ^user_id)
      |> Ash.read!(authorize?: false)

    enqueue_all(drafts, Magus.SuperBrain.Workers.ExtractDraft)
  end

  defp enqueue_all(records, worker_module) do
    Enum.each(records, fn %{id: id} ->
      %{"resource_id" => id}
      |> worker_module.new()
      |> Oban.insert!()
    end)

    Mix.shell().info("  enqueued #{length(records)} jobs")
  end
end
