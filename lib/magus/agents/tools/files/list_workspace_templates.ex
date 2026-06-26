defmodule Magus.Agents.Tools.Files.ListWorkspaceTemplates do
  @moduledoc """
  Lists workspace + personal templates accessible to the agent's actor,
  optionally filtered by a name substring. Returns a small payload
  (id, name, description, mime_type, file_size, is_template) so the
  agent can pick a candidate and then `file_download` it into the
  sandbox for processing.
  """

  use Jido.Action,
    name: "list_workspace_templates",
    description:
      "List the workspace's templates (files marked as templates). Use this to discover templates available to render new documents from. Accepts an optional `query` to filter by name substring.",
    schema: [
      query: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Optional name substring filter (case-insensitive)."
      ]
    ]

  alias Magus.Agents.Tools.Helpers

  def display_name, do: "Listing workspace templates..."

  def summarize_output(%{templates: list}) when is_list(list),
    do: "Found #{length(list)} template(s)."

  def summarize_output(%{error: e}), do: "Error: #{e}"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case Helpers.validate_context(context, [:user_id]) do
      {:ok, ctx} ->
        do_run(params, ctx)

      {:error, msg} ->
        {:ok, %{error: msg}}
    end
  end

  defp do_run(params, ctx) do
    user = Magus.Accounts.get_user!(ctx.user_id, authorize?: false)
    query = Helpers.get_param(params, :query)

    args = if is_binary(query) and query != "", do: %{query: query}, else: %{}

    case Magus.Files.list_templates(args, actor: user) do
      {:ok, files} ->
        {:ok,
         %{
           templates:
             Enum.map(files, fn f ->
               %{
                 id: f.id,
                 name: f.name,
                 description: Map.get(f, :description),
                 mime_type: f.mime_type,
                 file_size: f.file_size,
                 is_template: f.is_template
               }
             end)
         }}

      {:error, error} ->
        {:ok, %{error: Helpers.extract_error_message(error)}}
    end
  end
end
