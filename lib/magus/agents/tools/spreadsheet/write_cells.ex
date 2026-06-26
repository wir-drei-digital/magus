defmodule Magus.Agents.Tools.Spreadsheet.WriteCells do
  @moduledoc """
  Writes cells to an `.xlsx` file via the sandbox + openpyxl. Each change
  is `%{sheet, ref, value}` where `value` can be a string (use a leading
  `=` to write a formula), number, or boolean. Persists by replacing the
  File's binary content via `Magus.Files.replace_file_content/4` and
  broadcasts `{:file_updated, file_id, :agent, request_id}` so any open
  SpreadsheetCompanion can pick up the change.
  """

  use Jido.Action,
    name: "write_cells",
    description:
      "Write cell values to an .xlsx workbook. Use this to update specific cells the user is working on. Each change is {sheet, ref (A1-style), value}. Strings starting with '=' become formulas.",
    schema: [
      file_id: [type: :string, required: true, doc: "ID of the .xlsx file."],
      changes: [
        type: {:list, :map},
        required: true,
        doc: "List of %{sheet: \"Sheet1\", ref: \"A1\", value: ...}."
      ]
    ]

  alias Magus.Agents.Tools.Helpers
  alias Magus.Agents.Tools.Spreadsheet.Sandbox

  def display_name, do: "Updating spreadsheet..."

  def summarize_output(%{written: n}) when is_integer(n), do: "Wrote #{n} cell(s)."
  def summarize_output(%{error: e}), do: "Error: #{e}"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case Helpers.validate_context(context, [:user_id, :conversation_id]) do
      {:ok, ctx} ->
        do_run(params, ctx, context)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp do_run(params, ctx, context) do
    file_id = Map.get(params, "file_id") || Map.get(params, :file_id)
    changes = Map.get(params, "changes") || Map.get(params, :changes) || []
    request_id = Ecto.UUID.generate()

    with {:ok, user} <- Magus.Accounts.get_user(ctx.user_id),
         {:ok, file} <- Magus.Files.get_file(file_id, actor: user),
         {:ok, binary} <- Magus.Files.read_binary(file, actor: user),
         {:ok, new_binary} <- Sandbox.write_cells(binary, changes, context),
         {:ok, _file} <-
           Magus.Files.replace_file_content(
             file,
             new_binary,
             %{request_id: request_id, source: :agent},
             actor: user
           ) do
      {:ok, %{written: length(changes), request_id: request_id}}
    else
      {:error, :forbidden} ->
        {:ok, %{error: "You do not have permission to update this file."}}

      {:error, reason} ->
        {:ok, %{error: format_error(reason)}}
    end
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
