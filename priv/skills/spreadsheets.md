---
name: spreadsheets
description: Create new Excel (.xlsx) spreadsheets via openpyxl in the sandbox, and edit existing workspace spreadsheets live via read_sheet / write_cells (visible to the user in their SpreadsheetCompanion).
tags:
  - documents
  - office
  - data
tools:
  - run_code
  - exec_command
  - install_packages
  - sandbox_write_file
  - sandbox_read_file
  - sandbox_edit_file
  - sandbox_search
  - sandbox_list_files
  - sandbox_download_file
  - read_sheet
  - write_cells
---

# Spreadsheets

You help the user with two distinct workflows: **creating new** `.xlsx` files from scratch via `openpyxl` in the sandbox, and **editing existing** workspace `.xlsx` files live via `read_sheet` and `write_cells`. Pick the right path before doing anything.

## Decision: live editing vs sandbox creation

Use **`read_sheet` / `write_cells`** when:

- The user has an `.xlsx` file already in their workspace and is asking to inspect, change, or analyze specific cells.
- The user references a file by name ("update Q3 numbers in `Plan.xlsx`") rather than asking for a brand-new sheet.
- The user has the file open in a SpreadsheetCompanion tab in the workbench. Edits via `write_cells` appear in their grid live, with an "Updated by agent" toast.

Use the **sandbox + openpyxl** path when:

- The user wants a brand-new spreadsheet that does not exist yet.
- The user asks for charts, pivot tables, conditional formatting, or rich styling that the live tools do not preserve. (`read_sheet` / `write_cells` round-trip cell values and formulas only; advanced features are dropped on save.)
- You need to do bulk transformation across many cells or sheets in one pass and re-emitting the whole file is simpler.

If you are unsure, prefer `read_sheet` first to inspect, then decide. Do not `sandbox_download_file` an existing workbench file just to change one cell; use `write_cells`.

## Live editing workflow

1. Identify the file id. The user often references the workbook by name; use `file_search` or `file_list` to find it. If the file is the workbench's primary resource, the file id is in conversation context.
2. Call `read_sheet` with the `file_id` (and optional `sheet_name` / `range`) to see the current state. Results are capped at 5,000 cells per call; paginate with `range` if needed.
3. Decide what to change. Confirm with the user if the request is ambiguous.
4. Call `write_cells` with a list of `%{sheet, ref, value}` changes. Strings starting with `=` are formulas. Each call is atomic: either all cells write or none do.
5. After writing, the SpreadsheetCompanion (if open) refreshes automatically. Confirm in your reply what you changed and where.

## Known fidelity tradeoff

`read_sheet` and `write_cells` round-trip via SheetJS, the JS lib bridging Univer and `.xlsx` in the workbench. **Cell values and formulas survive. Charts, pivot tables, conditional formatting, and rich styling are dropped on save.** If the user's workbook has these features, warn them before calling `write_cells` and offer the sandbox path as an alternative (slower, lossless because openpyxl preserves formatting on round-trip).

# Creating new spreadsheets

You are helping the user create new Excel (.xlsx) spreadsheets from scratch using the `openpyxl` library. Follow these guidelines carefully.

## Preinstalled

`openpyxl` is preinstalled — no need to call `install_packages`.

## Tool Sequence

**Creating a new spreadsheet:**
1. `run_code` — Write and run Python code that generates the `.xlsx` file in `/workspace/`
2. `sandbox_download_file` — **Call this BEFORE mentioning the file in your response.** It returns a download URL you can then include as a link.

**Iterating on an existing script:**
1. `sandbox_read_file` — Read the Python script with line numbers
2. `sandbox_edit_file` — Make targeted edits (fix formulas, add columns, adjust styling, etc.)
3. `run_code` or `exec_command` — Re-run to regenerate the spreadsheet
4. `sandbox_download_file` — Download first, then include the link in your response

**Never rewrite an entire script to change a few lines.** Use `sandbox_edit_file` for targeted modifications.

## Workbook Basics

```python
from openpyxl import Workbook

wb = Workbook()
ws = wb.active
ws.title = "Sheet1"

# Write cells
ws["A1"] = "Name"
ws["B1"] = "Value"
ws.cell(row=2, column=1, value="Item A")
ws.cell(row=2, column=2, value=100)

# Append a row
ws.append(["Item B", 200])
ws.append(["Item C", 300])

# Add another sheet
ws2 = wb.create_sheet(title="Summary")

wb.save("/workspace/output.xlsx")
```

## Cell Formatting

```python
from openpyxl.styles import Font, PatternFill, Border, Side, Alignment

# Font
ws["A1"].font = Font(name="Arial", size=12, bold=True, color="FFFFFF")

# Background fill
ws["A1"].fill = PatternFill(fill_type="solid", start_color="4472C4")

# Borders
thin = Side(border_style="thin", color="000000")
ws["A1"].border = Border(top=thin, bottom=thin, left=thin, right=thin)

# Alignment
ws["A1"].alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
```

## Number Formats

```python
ws["B2"].number_format = "#,##0.00"         # 1,234.56
ws["B3"].number_format = "0.0%"             # 45.0%
ws["B4"].number_format = "$#,##0.00"        # $1,234.56
ws["B5"].number_format = "yyyy-mm-dd"       # 2026-02-09
ws["B6"].number_format = "yyyy-mm-dd hh:mm" # 2026-02-09 14:30
```

## Column Widths and Row Heights

```python
ws.column_dimensions["A"].width = 25
ws.column_dimensions["B"].width = 15
ws.row_dimensions[1].height = 30
```

## Merging Cells

```python
ws.merge_cells("A1:D1")
ws["A1"] = "Merged Header"
ws["A1"].alignment = Alignment(horizontal="center")
```

## Formulas

```python
ws["B10"] = "=SUM(B2:B9)"
ws["B11"] = "=AVERAGE(B2:B9)"
ws["B12"] = '=IF(B10>1000,"High","Low")'
```

## Styled Header Row Helper

```python
from openpyxl.styles import Font, PatternFill, Border, Side, Alignment

def style_header_row(ws, headers, row=1):
    """Write and style a header row."""
    header_font = Font(bold=True, color="FFFFFF", size=11)
    header_fill = PatternFill(fill_type="solid", start_color="4472C4")
    thin = Side(border_style="thin", color="000000")
    header_border = Border(top=thin, bottom=thin, left=thin, right=thin)
    center = Alignment(horizontal="center", vertical="center")

    for col, header in enumerate(headers, start=1):
        cell = ws.cell(row=row, column=col, value=header)
        cell.font = header_font
        cell.fill = header_fill
        cell.border = header_border
        cell.alignment = center
```

## Charts

```python
from openpyxl.chart import BarChart, LineChart, PieChart, Reference

# Bar chart
chart = BarChart()
chart.title = "Sales by Region"
chart.x_axis.title = "Region"
chart.y_axis.title = "Revenue"

# Data reference (column B, rows 1-5: row 1 is header)
data = Reference(ws, min_col=2, min_row=1, max_row=5)
categories = Reference(ws, min_col=1, min_row=2, max_row=5)
chart.add_data(data, titles_from_data=True)
chart.set_categories(categories)
ws.add_chart(chart, "D2")  # Place chart at cell D2

# Line chart
line = LineChart()
line.title = "Trend"
line.add_data(Reference(ws, min_col=2, min_row=1, max_row=13), titles_from_data=True)
line.set_categories(Reference(ws, min_col=1, min_row=2, max_row=13))
ws.add_chart(line, "D18")

# Pie chart
pie = PieChart()
pie.title = "Distribution"
pie.add_data(Reference(ws, min_col=2, min_row=1, max_row=5), titles_from_data=True)
pie.set_categories(Reference(ws, min_col=1, min_row=2, max_row=5))
ws.add_chart(pie, "D34")
```

## Freeze Panes

```python
# Freeze first row (header stays visible while scrolling)
ws.freeze_panes = "A2"

# Freeze first row and first column
ws.freeze_panes = "B2"
```

## Auto-Filter

```python
ws.auto_filter.ref = "A1:D100"
```

## Best Practices

- Always save to `/workspace/` so the file can be downloaded
- Style the header row to make spreadsheets look professional
- Set column widths to fit the content — openpyxl does not auto-fit
- Use `ws.append()` for writing rows of data efficiently
- Use `titles_from_data=True` on charts when the first row contains headers
- Freeze the header row with `ws.freeze_panes = "A2"` for usability
- Add number formats to monetary, percentage, and date columns
