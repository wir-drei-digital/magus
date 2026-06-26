defmodule Magus.Agents.Tools.Draft.ReadDraft do
  @moduledoc """
  Jido tool for reading a draft document with line numbers.

  Returns the full draft content formatted with line numbers so the agent
  can reference specific locations for surgical edits.

  Supports multiple drafts per conversation via optional `draft_id` parameter.
  """

  use Jido.Action,
    name: "read_draft",
    description: """
    Read a draft document with line numbers. Use this to see the full content before making targeted edits with write_draft.
    If draft_id is not provided, reads the active draft (the one currently open in the user's pane).
    """,
    schema: [
      draft_id: [
        type: {:or, [:string, nil]},
        required: false,
        default: nil,
        doc: "Optional draft ID to read. If not provided, reads the active draft."
      ]
    ]

  alias Magus.Agents.Tools.Helpers
  alias Magus.Agents.Tools.Draft.DraftHelpers
  alias Magus.Drafts.ProseMirrorConverter

  import Helpers, only: [validate_context: 2, get_param: 2, ai_actor: 0]

  def display_name, do: "Reading draft..."

  def summarize_output(%{title: title, line_count: n}), do: "#{title} (#{n} lines)"
  def summarize_output(%{error: _}), do: "No draft found"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id]) do
      {:ok, ctx} ->
        draft_id = get_param(params, :draft_id)

        case DraftHelpers.resolve_draft(ctx, draft_id, context) do
          {:ok, nil} ->
            {:ok,
             %{error: "No draft exists for this conversation. Use write_draft to create one."}}

          {:ok, draft} ->
            result = format_draft(draft)

            # Include list of other drafts if multiple exist
            case Magus.Drafts.list_drafts_for_conversation(ctx.conversation_id,
                   actor: ai_actor()
                 ) do
              {:ok, drafts} when length(drafts) > 1 ->
                others =
                  drafts
                  |> Enum.reject(&(&1.id == draft.id))
                  |> Enum.map(&%{id: &1.id, title: &1.title, version: &1.version})

                {:ok, Map.put(result, :other_drafts, others)}

              _ ->
                {:ok, result}
            end

          {:error, error} ->
            {:ok, %{error: Helpers.extract_error_message(error)}}
        end

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp format_draft(draft) do
    markdown = ProseMirrorConverter.to_markdown(draft.content)
    lines = String.split(markdown, "\n")
    line_count = length(lines)
    max_width = line_count |> Integer.to_string() |> String.length()

    numbered_content =
      lines
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {line, num} ->
        padded = num |> Integer.to_string() |> String.pad_leading(max_width)
        "#{padded}  #{line}"
      end)

    %{
      draft_id: draft.id,
      title: draft.title,
      version: draft.version,
      line_count: line_count,
      content:
        "Title: #{draft.title} (version #{draft.version}, #{line_count} lines)\n---\n#{numbered_content}\n---"
    }
  end
end
