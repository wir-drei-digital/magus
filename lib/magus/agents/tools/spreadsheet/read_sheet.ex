defmodule Magus.Agents.Tools.Spreadsheet.ReadSheet do
  @moduledoc """
  Reads sheet data from an `.xlsx` file via the sandbox + openpyxl.
  Returns a structured view of cells (`ref`, `value`, `formula`) for the
  requested sheet(s) and range. Caps the result at 5,000 cells per call so
  the LLM context cannot be blown up by a single tool call.
  """

  use Jido.Action,
    name: "read_sheet",
    description:
      "Read cells from an .xlsx workbook. Use this to inspect the user's spreadsheet before deciding what to change. Optionally restrict to a single sheet and/or A1-style range.",
    schema: [
      file_id: [type: :string, required: true, doc: "ID of the .xlsx file."],
      sheet_name: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Optional: limit the result to one sheet by name."
      ],
      range: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Optional A1-style range (e.g. \"A1:D20\")."
      ]
    ]

  alias Magus.Agents.Tools.Helpers
  alias Magus.Agents.Tools.Spreadsheet.Sandbox

  @max_cells 5_000
  @xlsx_mime "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  def display_name, do: "Reading spreadsheet..."

  def summarize_output(%{sheets: sheets}) when is_list(sheets) do
    cell_count = sheets |> Enum.flat_map(& &1.cells) |> length()
    "Read #{cell_count} cell(s) from #{length(sheets)} sheet(s)."
  end

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
    sheet_name = Map.get(params, "sheet_name") || Map.get(params, :sheet_name)
    range = Map.get(params, "range") || Map.get(params, :range)

    with {:ok, user} <- Magus.Accounts.get_user(ctx.user_id),
         {:ok, file} <- Magus.Files.get_file(file_id, actor: user),
         :ok <- ensure_xlsx(file),
         {:ok, binary} <- Magus.Files.read_binary(file, actor: user),
         {:ok, payload} <- Sandbox.read_sheet(binary, sheet_name, range, @max_cells, context) do
      {:ok, %{sheets: payload.sheets}}
    else
      {:error, :not_xlsx} ->
        {:ok, %{error: "File is not an .xlsx workbook."}}

      {:error, :forbidden} ->
        {:ok, %{error: "You do not have permission to read this file."}}

      {:error, reason} ->
        {:ok, %{error: format_error(reason)}}
    end
  end

  defp ensure_xlsx(%{mime_type: @xlsx_mime}), do: :ok

  defp ensure_xlsx(%{name: name}) when is_binary(name) do
    if String.ends_with?(String.downcase(name), ".xlsx"), do: :ok, else: {:error, :not_xlsx}
  end

  defp ensure_xlsx(_), do: {:error, :not_xlsx}

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
