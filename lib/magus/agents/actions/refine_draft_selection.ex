defmodule Magus.Agents.Actions.RefineDraftSelection do
  @moduledoc """
  Standalone Jido Action for refining selected text in a draft via LLM.

  Called directly from the LiveView when the user clicks "Refine Selection" —
  NOT a tool the LLM calls. Keeps the refinement loop tight and fast without
  polluting the conversation history with internal edits.

  The browser sends the selected text together with the full parent node text
  (`node_context`) so the LLM can see the complete paragraph/heading around
  the selection without expensive document-level context extraction.
  """

  use Jido.Action,
    name: "refine_draft_selection",
    description: "Refine a selected section of a draft document",
    schema: [
      draft_id: [type: :string, required: true, doc: "Draft ID"],
      selected_text: [type: :string, required: true, doc: "The selected text to refine"],
      node_context: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Full text of the parent block node(s) containing the selection"
      ],
      hint_line: [
        type: {:or, [:integer, nil]},
        default: nil,
        doc: "Approximate line of selection"
      ],
      instruction: [type: :string, default: "Improve this text", doc: "Refinement instruction"],
      user_id: [type: :string, required: true, doc: "User ID"],
      conversation_id: [type: :string, required: true, doc: "Conversation ID"]
    ]

  require Logger

  alias Magus.Agents.Config
  alias Magus.Agents.Clients.LLM, as: LLMClient
  alias Magus.Drafts.MarkdownResolver
  alias Magus.Drafts.ProseMirrorConverter

  import Magus.Agents.Tools.Helpers, only: [ai_actor: 0]

  @impl true
  def run(params, _context) do
    model = Config.summary_model()

    case Magus.Drafts.get_draft(params.draft_id, actor: ai_actor()) do
      {:ok, draft} ->
        refine(draft, params, model)

      {:error, error} ->
        {:error, error}
    end
  end

  defp refine(draft, params, model) do
    selected = params.selected_text
    markdown = ProseMirrorConverter.to_markdown(draft.content)
    raw_section = MarkdownResolver.resolve(markdown, selected, params.hint_line)
    node_context = params.node_context
    prompt = build_prompt(raw_section, selected, node_context, params.instruction)

    context =
      ReqLLM.Context.new([
        ReqLLM.Context.user(prompt)
      ])

    case LLMClient.llm_client().generate_text(model, context, []) do
      {:ok, response} ->
        new_text = ReqLLM.Response.text(response) |> String.trim()

        case Magus.Drafts.replace_draft_text(
               draft,
               raw_section,
               new_text,
               params.hint_line,
               actor: ai_actor()
             ) do
          {:ok, updated} ->
            broadcast_refined(updated, params)
            {:ok, %{new_text: new_text, version: updated.version}}

          {:error, error} ->
            {:error, error}
        end

      {:error, error} ->
        Logger.error("RefineDraftSelection LLM call failed: #{inspect(error)}")
        {:error, error}
    end
  end

  # -- Prompt construction ----------------------------------------------------

  defp build_prompt(raw_section, selected, node_context, instruction)
       when raw_section == selected do
    """
    You are editing a document. Rewrite ONLY the selected text according to the instruction.

    #{context_block(node_context, selected)}

    Selected text:
    "#{selected}"

    Instruction: #{instruction}

    Return ONLY the rewritten text for the selection, nothing else. No line numbers, no quotes, no explanation.
    """
  end

  defp build_prompt(raw_section, selected, node_context, instruction) do
    """
    You are editing a markdown document. The user selected some rendered text that
    corresponds to the following raw markdown section.

    #{context_block(node_context, selected)}

    Raw markdown section to rewrite:
    "#{raw_section}"

    The user's rendered selection was approximately:
    "#{selected}"

    Instruction: #{instruction}

    Rewrite the raw markdown section according to the instruction. Preserve markdown formatting.
    Return ONLY the rewritten raw markdown, nothing else. No line numbers, no quotes, no explanation.
    """
  end

  defp context_block(nil, _selected), do: ""
  defp context_block("", _selected), do: ""

  defp context_block(node_context, selected) when node_context == selected, do: ""

  defp context_block(node_context, _selected) do
    """
    Full paragraph/block containing the selection (for reference only — do NOT include in your output):
    ---
    #{node_context}
    ---\
    """
  end

  defp broadcast_refined(draft, params) do
    Magus.Endpoint.broadcast(
      "drafts:conversation:#{params.conversation_id}",
      "draft.refined",
      %{draft: draft}
    )
  end
end
