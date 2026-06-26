defmodule Magus.Agents.Tools.Threads.CreateThread do
  @moduledoc "Agent tool for creating a thread from a specific message."

  use Jido.Action,
    name: "create_thread",
    description:
      "Create a new thread branching from a message to explore a topic in depth without polluting the main conversation. If message_id is omitted, branches from the latest agent message.",
    schema: [
      message_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "The message ID to branch from. If omitted, uses the latest agent message."
      ],
      title: [type: {:or, [:string, nil]}, default: nil, doc: "Optional title for the thread"],
      initial_message: [
        type: :string,
        required: true,
        doc: "The first message to send in the thread"
      ]
    ]

  require Ash.Query
  require Logger

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2]

  alias Magus.Agents.Signals
  alias Magus.Chat

  def display_name, do: "Creating thread..."

  def summarize_output(%{thread_conversation_id: id, title: title}),
    do: "Created thread: #{title || id}"

  def summarize_output(%{error: e}), do: "Error: #{e}"
  def summarize_output(_), do: "Thread created"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id, :user_id, :user]) do
      {:ok, ctx} -> create_thread(params, ctx, context)
      {:error, message} -> {:ok, %{error: message}}
    end
  end

  defp create_thread(params, ctx, context) do
    title = params["title"]
    initial_message = params["initial_message"]

    Signals.emit_tool_progress(context, :creating, %{title: title || "new thread"})

    with {:ok, message} <- resolve_branch_message(params["message_id"], ctx),
         {:ok, thread} <-
           Chat.create_thread(
             %{
               parent_conversation_id: ctx.conversation_id,
               branched_at_message_id: message.id,
               title: title
             },
             actor: ctx.user
           ),
         {:ok, _msg} <-
           Chat.send_user_message(
             %{
               text: initial_message,
               conversation_id: thread.id
             },
             actor: ctx.user
           ) do
      title_part = if title, do: ~s[ "#{title}"], else: ""

      announcement_text =
        "I've started a thread#{title_part} to explore this topic in detail."

      # Announcement is best-effort — don't fail the tool if it errors
      case Chat.upsert_event_message(
             Ash.UUID.generate(),
             announcement_text,
             ctx.conversation_id,
             %{
               "thread_announcement" => true,
               "thread_conversation_id" => thread.id,
               "branched_at_message_id" => message.id,
               "status" => "complete"
             },
             true,
             actor: ctx.user
           ) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to post thread announcement: #{inspect(reason)}")
      end

      {:ok, %{thread_conversation_id: thread.id, title: title || thread.title}}
    else
      {:error, reason} ->
        {:ok, %{error: "Failed to create thread: #{inspect(reason)}"}}
    end
  end

  defp resolve_branch_message(nil, ctx) do
    case Magus.Chat.Message
         |> Ash.Query.filter(
           conversation_id == ^ctx.conversation_id and
             source == :agent and
             message_type == :message and
             status == :complete and
             disabled != true
         )
         |> Ash.Query.sort(inserted_at: :desc)
         |> Ash.Query.limit(1)
         |> Ash.read(actor: ctx.user) do
      {:ok, [message]} -> {:ok, message}
      {:ok, []} -> {:error, "No agent messages found to branch from"}
      {:error, reason} -> {:error, "Failed to find branch message: #{inspect(reason)}"}
    end
  end

  defp resolve_branch_message(message_id, ctx) do
    Chat.get_message(message_id, actor: ctx.user)
  end
end
