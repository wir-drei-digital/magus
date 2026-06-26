defmodule Magus.Agents.Tools.CreateNote do
  @moduledoc """
  Tool for creating markdown notes that are stored and indexed for RAG retrieval.

  This allows the AI to create persistent notes during a conversation that can
  be searched and referenced later. Notes are stored as markdown files and
  processed through the same pipeline as user-uploaded files.

  ## Usage with Jido AI

      # As a tool in ChatResponder with context
      tools = [Magus.Agents.Tools.CreateNote]
      tool_contexts = %{
        Magus.Agents.Tools.CreateNote => %{
          user_id: user.id,
          conversation_id: conversation.id,
          folder_id: folder_id
        }
      }

  ## Example

      Input: %{title: "Meeting Notes", content: "# Summary\\n\\nKey points..."}
      Output: %{success: true, name: "Meeting Notes.md", message: "Note created..."}
  """

  use Jido.Action,
    name: "create_note",
    description: """
    Create a markdown note and store it for later reference.
    Use this tool when you need to save information, summaries, or notes that the user
    might want to reference later. The note will be searchable through the knowledge base.
    Good for: meeting notes, summaries, research findings, reference materials, etc.
    """,
    schema: [
      title: [
        type: :string,
        required: true,
        doc: "The title of the note (will be used as filename)"
      ],
      content: [
        type: :string,
        required: true,
        doc: "The markdown content of the note"
      ]
    ]

  require Logger

  alias Magus.Files.Storage

  @doc "User-friendly display name shown in the UI when this tool is executing"
  def display_name, do: "Creating note..."

  @doc "Generate a human-readable summary of the tool output for UI display"
  def summarize_output(%{success: true, name: name}), do: "Created: #{name}"
  def summarize_output(%{success: true}), do: "Note created"
  def summarize_output(%{success: false}), do: "Error"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  import Magus.Agents.Tools.Helpers, only: [get_param: 3]

  @impl true
  def run(params, context) do
    title = get_param(params, :title, "Untitled Note")
    content = get_param(params, :content, "")

    # Handle both atom and string keys in context
    user_id = get_context_value(context, :user_id)
    conversation_id = get_context_value(context, :conversation_id)
    folder_id = get_context_value(context, :folder_id)

    Logger.debug("CreateNote: executing with context",
      user_id: user_id,
      conversation_id: conversation_id,
      folder_id: folder_id,
      context: inspect(context)
    )

    if is_nil(user_id) do
      {:ok, %{error: "No user context available", context: inspect(context)}}
    else
      create_note(title, content, user_id, conversation_id, folder_id)
    end
  end

  defp get_context_value(context, key) when is_map(context) do
    Map.get(context, key) || Map.get(context, to_string(key))
  end

  defp get_context_value(_, _), do: nil

  defp create_note(title, content, user_id, conversation_id, folder_id) do
    # Sanitize title for filename
    filename = sanitize_filename(title) <> ".md"

    # Generate a temporary unique ID for storage path (resource will get its own ID)
    temp_id = Ash.UUIDv7.generate()

    # Generate storage path
    relative_path = Storage.generate_path(user_id, temp_id, filename)

    Logger.info("CreateNote: storing note",
      title: title,
      path: relative_path,
      content_length: String.length(content)
    )

    # Store the file
    case Storage.store(relative_path, content) do
      {:ok, _} ->
        # Create the resource record (triggers processing via Oban)
        create_resource(
          filename,
          relative_path,
          content,
          user_id,
          conversation_id,
          folder_id
        )

      {:error, reason} ->
        Logger.error("CreateNote: storage failed", error: inspect(reason))

        {:ok,
         %{
           success: false,
           error: "Failed to store note: #{inspect(reason)}"
         }}
    end
  end

  defp create_resource(
         filename,
         relative_path,
         content,
         user_id,
         conversation_id,
         folder_id
       ) do
    attrs = %{
      name: filename,
      type: :text,
      mime_type: "text/markdown",
      file_size: byte_size(content),
      file_path: relative_path,
      metadata: %{source: "ai_created"},
      conversation_id: conversation_id,
      folder_id: folder_id,
      user_id: user_id
    }

    # Create file using the create_for_user action (ID auto-generated)
    case Magus.Files.File
         |> Ash.Changeset.for_create(:create_for_user, attrs, authorize?: false)
         |> Ash.create() do
      {:ok, file} ->
        Logger.info("CreateNote: file created", file_id: file.id)

        {:ok,
         %{
           success: true,
           name: filename,
           file_id: file.id,
           message:
             "Note '#{filename}' has been created and will be available for search shortly."
         }}

      {:error, %Ash.Error.Invalid{} = error} ->
        error_details = Ash.Error.Invalid.message(error)
        Logger.error("CreateNote: resource creation failed - #{error_details}")

        {:ok,
         %{
           success: false,
           error: "Failed to create note record: #{error_details}"
         }}

      {:error, error} ->
        Logger.error("CreateNote: resource creation failed - #{inspect(error)}")

        {:ok,
         %{
           success: false,
           error: "Failed to create note record: #{inspect(error)}"
         }}
    end
  end

  defp sanitize_filename(title) do
    title
    |> String.trim()
    |> String.replace(~r/[^\w\s\-]/, "")
    |> String.replace(~r/\s+/, "_")
    |> String.slice(0, 100)
    |> case do
      "" -> "untitled"
      name -> name
    end
  end
end
