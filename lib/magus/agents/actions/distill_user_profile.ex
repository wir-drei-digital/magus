defmodule Magus.Agents.Actions.DistillUserProfile do
  @moduledoc """
  Rewrites the distilled user profile document (Hermes-style working memory).

  Reads the current document, the bucket's active user-scope memories, and
  pending agent notes, then asks the LLM to REWRITE the whole document under
  a hard token cap. Rewriting (not merging) is the mechanism that resolves
  contradictions and drops completed or one-off information. Runs from the
  daily ConsolidateMemories pass; safe to call ad hoc.
  """

  use Jido.Action,
    name: "distill_user_profile",
    description: "Rewrites the distilled user profile document from user-scope memories",
    schema: [
      user_id: [type: :string, required: true, doc: "User ID"],
      workspace_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Workspace bucket (nil = personal)"
      ],
      model: [type: {:or, [:string, nil]}, default: nil, doc: "Model key override"]
    ]

  alias Magus.Agents.Clients.LLM, as: LLMClient
  alias Magus.Agents.Config
  alias Magus.Agents.Persistence.UsageRecorder
  alias Magus.Agents.Support.AiAgent
  alias Magus.Memory

  @actor %AiAgent{}
  @max_chars 3200
  @max_memories 50

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "document" => %{
        "type" => "string",
        "description" => "The complete rewritten profile document (markdown)"
      }
    },
    "required" => ["document"]
  }

  @impl true
  def run(params, _context) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)
    user_id = params["user_id"]
    workspace_id = params["workspace_id"]
    model = params["model"] || Config.extraction_model()

    with {:ok, profile} <- get_or_create_profile(user_id, workspace_id),
         memories = load_memories(user_id, workspace_id),
         {:ok, document, usage} <- generate_document(model, profile, memories),
         {:ok, updated} <-
           Memory.set_profile_document(profile, %{document: document}, actor: @actor) do
      record_usage(user_id, model, usage)
      {:ok, %{document: updated.document, token_estimate: updated.token_estimate}}
    end
  end

  # `get_user_profile` (`:for_bucket`, `get? true`) defaults to
  # `not_found_error?: true`, so a bucket with no row yet returns
  # `{:error, %Ash.Error.Query.NotFound{}}` rather than `{:ok, nil}`. Treat any
  # non-success as "no profile yet" and create the (empty-document) row.
  #
  # `unique_bucket` (`user_id`, `workspace_id`) makes this racy: if another
  # caller (e.g. the UpdateProfile tool, or a concurrent Oban retry) wins a
  # concurrent create for the same brand-new bucket, ours comes back as an
  # `{:error, %Ash.Error.Invalid{}}` unique-index violation. Re-read once
  # rather than aborting, so we use the row that now exists instead of
  # silently dropping this distillation.
  defp get_or_create_profile(user_id, workspace_id) do
    case Memory.get_user_profile(user_id, workspace_id, actor: @actor) do
      {:ok, profile} when not is_nil(profile) ->
        {:ok, profile}

      _ ->
        case Memory.create_user_profile(user_id, workspace_id, %{document: ""}, actor: @actor) do
          {:ok, profile} ->
            {:ok, profile}

          {:error, _} ->
            Memory.get_user_profile(user_id, workspace_id, actor: @actor)
        end
    end
  end

  defp load_memories(user_id, workspace_id) do
    actor = %Magus.Accounts.User{id: user_id}

    case Memory.list_user_memories(workspace_id, actor: actor) do
      {:ok, memories} -> Enum.take(memories, @max_memories)
      _ -> []
    end
  end

  defp generate_document(model, profile, memories) do
    prompt = build_prompt(profile, memories)

    with {:ok, document, usage} <- call_llm(model, prompt) do
      if String.length(document) <= @max_chars do
        {:ok, document, usage}
      else
        retry_prompt =
          prompt <>
            "\n\nYour previous draft was #{String.length(document)} characters, over the " <>
            "#{@max_chars} character limit. Rewrite it under the limit by dropping the " <>
            "least durable information."

        case call_llm(model, retry_prompt) do
          {:ok, retried, retry_usage} when byte_size(retried) > 0 ->
            if String.length(retried) <= @max_chars do
              {:ok, retried, retry_usage}
            else
              {:error, :document_too_long}
            end

          _ ->
            {:error, :document_too_long}
        end
      end
    end
  end

  defp call_llm(model, prompt) do
    case LLMClient.llm_client().generate_object(model, prompt, @output_schema,
           system_prompt: system_prompt()
         ) do
      {:ok, response} -> {:ok, to_string(response.object["document"] || ""), response.usage}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_prompt(profile, memories) do
    """
    ## Current Profile Document

    #{if profile.document == "", do: "(empty)", else: profile.document}

    ## Stored User Memories (most recent first)

    #{format_memories(memories)}

    ## Pending Notes From Recent Sessions

    #{format_notes(profile.pending_notes)}

    ## Instructions

    Rewrite the COMPLETE profile document now, following the system rules.
    """
  end

  defp format_memories([]), do: "None"

  defp format_memories(memories) do
    Enum.map_join(memories, "\n", fn m ->
      kind = if m.kind && m.kind != :general, do: " [#{m.kind}]", else: ""

      "- **#{m.name}**#{kind} (updated #{Date.to_iso8601(DateTime.to_date(m.updated_at))}): #{m.summary || "(no summary)"}"
    end)
  end

  defp format_notes([]), do: "None"
  defp format_notes(notes), do: Enum.map_join(notes, "\n", &("- " <> &1))

  defp system_prompt do
    """
    You maintain a single distilled profile document for a user. You rewrite
    the ENTIRE document from scratch each time, based on the current document,
    the user's stored memories, and pending notes.

    Structure (markdown, only these sections, omit ones that would be empty):
    ## Current Focus
    ## Active Projects
    ## Behavioral Patterns
    ## Preferences
    ## Open Threads

    Rules:
    - Hard limit: #{@max_chars} characters (~800 tokens). Compression is the
      point: keep only signal that has repeated or proven durable.
    - Update, do not append: replace outdated statements instead of adding
      qualifiers to them.
    - Resolve contradictions in favor of the most recently updated source.
    - Drop completed work and one-off facts with no behavioral relevance.
    - At most 4 active projects.
    - Plain declarative statements. No preamble, no meta-commentary.
    """
  end

  # This is a background maintenance action with no conversation, so
  # `conversation_id` is omitted entirely rather than passed as `nil`
  # (UsageRecorder defaults it to nil via `Keyword.get/3` either way).
  # `record!/1` already never raises (it wraps `record/1`, which itself
  # rescues everything and returns `{:error, e}`), so no local rescue is
  # needed here.
  defp record_usage(user_id, model_key, usage) do
    UsageRecorder.record!(
      user_id: user_id,
      model_key: model_key,
      usage: usage,
      usage_type: :response,
      billable: false,
      action_name: "distill_user_profile"
    )
  end
end
