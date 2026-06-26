defmodule Magus.Agents.Tools.Spreadsheet.Sandbox do
  @moduledoc """
  Thin wrapper around `Magus.Sandbox.Orchestrator` that runs Python +
  openpyxl programs to read and write `.xlsx` workbooks for the
  `read_sheet` and `write_cells` tools.

  Both helpers ship the workbook into the sandbox as a workspace file,
  execute a self-contained Python script, and parse the JSON or base64
  response written to stdout. The sandbox install of `openpyxl` is
  attempted ahead of execution; failures fall through to the regular
  error normalization paths (the LLM gets a structured error, not a
  crash).
  """

  alias Magus.Sandbox.Orchestrator

  @input_filename "input.xlsx"
  @output_filename "output.xlsx"

  @timeout_ms 120_000

  @doc """
  Read cells from an `.xlsx` workbook in the sandbox.

  Accepts the raw binary plus optional sheet/range filters and a cap on
  the number of cells returned. Returns `{:ok, %{sheets: [...]}}` on
  success or `{:error, reason}` on any failure.
  """
  @spec read_sheet(binary(), String.t() | nil, String.t() | nil, pos_integer(), map()) ::
          {:ok, map()} | {:error, term()}
  def read_sheet(binary, sheet_name, range, max_cells, context) do
    user_id = Map.get(context, :user_id) || Map.get(context, "user_id")

    conversation_id =
      Map.get(context, :conversation_id) ||
        Map.get(context, "conversation_id") ||
        Map.get(context, :__conversation_id__) ||
        Map.get(context, "__conversation_id__")

    code = read_program(sheet_name, range, max_cells)

    opts = [
      timeout_ms: @timeout_ms,
      user_id: user_id,
      files: [%{name: @input_filename, content: binary}]
    ]

    with :ok <- maybe_install(conversation_id, user_id),
         {:ok, result} <- Orchestrator.execute(conversation_id, code, opts),
         {:ok, json} <- ensure_success(result),
         {:ok, payload} <- Jason.decode(json) do
      {:ok, normalize_read(payload)}
    end
  end

  @doc """
  Apply a list of `%{sheet, ref, value}` changes to an `.xlsx` workbook
  binary. Returns `{:ok, new_binary}` with the modified workbook or
  `{:error, reason}` on failure.
  """
  @spec write_cells(binary(), list(map()), map()) ::
          {:ok, binary()} | {:error, term()}
  def write_cells(binary, changes, context) do
    user_id = Map.get(context, :user_id) || Map.get(context, "user_id")

    conversation_id =
      Map.get(context, :conversation_id) ||
        Map.get(context, "conversation_id") ||
        Map.get(context, :__conversation_id__) ||
        Map.get(context, "__conversation_id__")

    normalized_changes = Enum.map(changes, &normalize_change/1)

    case Jason.encode(%{changes: normalized_changes}) do
      {:ok, changes_json} ->
        code = write_program(changes_json)

        opts = [
          timeout_ms: @timeout_ms,
          user_id: user_id,
          files: [%{name: @input_filename, content: binary}]
        ]

        with :ok <- maybe_install(conversation_id, user_id),
             {:ok, result} <- Orchestrator.execute(conversation_id, code, opts),
             {:ok, _stdout} <- ensure_success(result),
             {:ok, %{content: new_binary}} <-
               Orchestrator.read_file(conversation_id, "/workspace/" <> @output_filename,
                 user_id: user_id
               ) do
          {:ok, new_binary}
        end

      {:error, reason} ->
        {:error, {:invalid_changes, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Python program templates
  # ---------------------------------------------------------------------------

  defp read_program(sheet_name, range, max_cells) do
    """
    import json
    from openpyxl import load_workbook

    INPUT_PATH = "/workspace/#{@input_filename}"
    SHEET_NAME = #{python_string_or_none(sheet_name)}
    RANGE = #{python_string_or_none(range)}
    CAP = #{max_cells}

    wb = load_workbook(INPUT_PATH, data_only=False)


    def cells_for(ws, rng):
        seen = 0
        out = []
        if rng:
            iter_ = ws[rng]
            if not isinstance(iter_, tuple):
                iter_ = (iter_,)
        else:
            iter_ = ws.iter_rows()
        for row in iter_:
            if not isinstance(row, tuple):
                row = (row,)
            for cell in row:
                if cell.value is None:
                    continue
                seen += 1
                if seen > CAP:
                    return out, True
                value = cell.value
                formula = None
                if isinstance(value, str) and value.startswith("="):
                    formula = value
                    value = None
                out.append({"ref": cell.coordinate, "value": value, "formula": formula})
        return out, False


    sheets = []
    for name in wb.sheetnames:
        if SHEET_NAME and name != SHEET_NAME:
            continue
        ws = wb[name]
        cells, truncated = cells_for(ws, RANGE)
        sheets.append({
            "name": name,
            "used_range": ws.dimensions if ws.dimensions != "A1:A1" else None,
            "cells": cells,
            "truncated": truncated,
        })

    print(json.dumps({"sheets": sheets}))
    """
  end

  defp write_program(changes_json) do
    """
    import json
    from openpyxl import load_workbook

    INPUT_PATH = "/workspace/#{@input_filename}"
    OUTPUT_PATH = "/workspace/#{@output_filename}"

    payload = json.loads(#{python_triple_quoted(changes_json)})
    changes = payload["changes"]

    wb = load_workbook(INPUT_PATH)

    for c in changes:
        sheet_name = c["sheet"]
        if sheet_name not in wb.sheetnames:
            wb.create_sheet(sheet_name)
        ws = wb[sheet_name]
        ws[c["ref"]] = c["value"]

    wb.save(OUTPUT_PATH)
    print("OK")
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp normalize_change(change) when is_map(change) do
    %{
      "sheet" => Map.get(change, "sheet") || Map.get(change, :sheet),
      "ref" => Map.get(change, "ref") || Map.get(change, :ref),
      "value" => Map.get(change, "value") || Map.get(change, :value)
    }
  end

  defp normalize_change(other), do: other

  defp normalize_read(%{"sheets" => sheets}) when is_list(sheets) do
    %{
      sheets:
        Enum.map(sheets, fn s ->
          %{
            name: Map.get(s, "name"),
            used_range: Map.get(s, "used_range"),
            truncated: Map.get(s, "truncated", false),
            cells:
              Enum.map(Map.get(s, "cells", []), fn cell ->
                %{
                  ref: Map.get(cell, "ref"),
                  value: Map.get(cell, "value"),
                  formula: Map.get(cell, "formula")
                }
              end)
          }
        end)
    }
  end

  defp normalize_read(other), do: %{sheets: [], raw: other}

  defp ensure_success(%{exit_code: 0, stdout: stdout}), do: {:ok, stdout || ""}

  defp ensure_success(%{exit_code: code, stderr: stderr}),
    do: {:error, {:nonzero_exit, code, stderr}}

  defp ensure_success(other), do: {:error, {:unexpected_result, other}}

  defp maybe_install(_conversation_id, nil), do: {:error, :missing_user_id}

  defp maybe_install(nil, _user_id), do: {:error, :missing_conversation_id}

  defp maybe_install(conversation_id, user_id) do
    case Orchestrator.install_packages(conversation_id, ["openpyxl"], user_id: user_id) do
      {:ok, _} -> :ok
      # Already installed or non-fatal warning; proceed and let the run surface real errors.
      {:error, _kind, _details} -> :ok
    end
  end

  defp python_string_or_none(nil), do: "None"
  defp python_string_or_none(""), do: "None"
  defp python_string_or_none(value) when is_binary(value), do: inspect(value)

  defp python_triple_quoted(value) when is_binary(value) do
    # Use a Python r-string to avoid escape-sequence interpretation, with a
    # delimiter that is highly unlikely to appear in a JSON payload.
    safe = String.replace(value, "'''", "\\'\\'\\'")
    "r'''" <> safe <> "'''"
  end
end
