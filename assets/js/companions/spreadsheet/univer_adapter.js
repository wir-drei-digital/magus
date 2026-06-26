// Thin shim around Univer. Hides the library's API behind a small surface
// (`initUniverFromBinary`, `exportXlsx`, `applyPatch`, `debounce`) so the
// rest of the app does not depend on Univer-specific shapes. Swapping to
// a different spreadsheet library later is a rewrite of this file only.
//
// xlsx <-> Univer-snapshot conversion:
// Univer 0.21.x does NOT ship a built-in xlsx import/export helper (the
// dream-num/univer-pro xlsx plugin is paid + closed source). We bridge
// via SheetJS (the `xlsx` npm package, Apache 2.0). SheetJS parses the
// .xlsx into a JSON sheet model; we walk that model and emit Univer's
// IWorkbookData snapshot. For export we walk Univer's runtime workbook
// back into a SheetJS workbook and serialize to .xlsx. This preserves
// cell values and formulas; advanced styling, charts, pivot tables, and
// other rich features are NOT round-tripped through this shim.
//
// The adapter exposes itself on `window.UniverAdapter` so the colocated
// hook script (which runs in a separate compilation unit produced by
// Phoenix's :phoenix_live_view compiler) can call into it without
// having to resolve relative imports.

import { Univer, UniverInstanceType, LocaleType } from "@univerjs/core";
import { UniverSheetsPlugin } from "@univerjs/sheets";
import { UniverSheetsUIPlugin } from "@univerjs/sheets-ui";
import * as XLSX from "xlsx";

export function debounce(fn, ms) {
  let t;
  return (...args) => {
    clearTimeout(t);
    t = setTimeout(() => fn(...args), ms);
  };
}

export function initUniverFromBinary(el, binary, onChange) {
  const univer = new Univer({ locale: LocaleType.EN_US });
  univer.registerPlugin(UniverSheetsPlugin);
  univer.registerPlugin(UniverSheetsUIPlugin, { container: el });

  const snapshot = binaryToSnapshot(binary);
  const workbook = univer.createUnit(UniverInstanceType.UNIVER_SHEET, snapshot);

  // Subscribe to cell-change events. Newer Univer versions expose this
  // via the command service; for now we lean on an optional method so
  // missing wiring degrades gracefully (the user can still save by
  // closing/reopening the tab).
  if (typeof workbook?.onCellValueChanged === "function") {
    workbook.onCellValueChanged(() => onChange());
  }

  return {
    workbook,
    univer,
    snapshot,
    replaceWorkbook(newBinary) {
      univer.dispose(this.workbook);
      const nextSnapshot = binaryToSnapshot(newBinary);
      this.workbook = univer.createUnit(
        UniverInstanceType.UNIVER_SHEET,
        nextSnapshot,
      );
      this.snapshot = nextSnapshot;
    },
    dispose() {
      univer.dispose(this.workbook);
    },
  };
}

export function exportXlsx(handle) {
  return snapshotToBinary(handle.workbook, handle.snapshot);
}

export function applyPatch(handle, changes) {
  for (const c of changes) {
    const sheet = handle.workbook?.getSheetByName?.(c.sheet);
    if (sheet?.setCellValue) {
      sheet.setCellValue(c.ref, c.value);
    }
  }
}

// ---------------------------------------------------------------------------
// .xlsx <-> Univer snapshot bridge (via SheetJS)
// ---------------------------------------------------------------------------

const APP_VERSION = "3.0.0-alpha";

// Convert raw .xlsx bytes (Uint8Array) into a Univer IWorkbookData snapshot.
// SheetJS parses the workbook; we walk every sheet, build Univer's cellData
// matrix (`{ [row]: { [col]: { v, f } } }`), and emit a snapshot that the
// Univer engine can mount.
function binaryToSnapshot(binary) {
  const wb = XLSX.read(binary, { type: "array", cellFormula: true });

  const id = randomId();
  const sheetOrder = [];
  const sheets = {};

  for (const name of wb.SheetNames) {
    const ws = wb.Sheets[name];
    const sheetId = randomId();
    sheetOrder.push(sheetId);

    const cellData = {};
    let maxRow = 0;
    let maxCol = 0;

    if (ws && ws["!ref"]) {
      const range = XLSX.utils.decode_range(ws["!ref"]);
      for (let r = range.s.r; r <= range.e.r; r++) {
        for (let c = range.s.c; c <= range.e.c; c++) {
          const addr = XLSX.utils.encode_cell({ r, c });
          const cell = ws[addr];
          if (!cell) continue;

          const univerCell = sheetjsCellToUniver(cell);
          if (univerCell === null) continue;

          if (!cellData[r]) cellData[r] = {};
          cellData[r][c] = univerCell;
          if (r > maxRow) maxRow = r;
          if (c > maxCol) maxCol = c;
        }
      }
    }

    sheets[sheetId] = {
      id: sheetId,
      name,
      cellData,
      rowCount: Math.max(maxRow + 1, 100),
      columnCount: Math.max(maxCol + 1, 26),
    };
  }

  // Empty workbook safety net: Univer expects at least one sheet.
  if (sheetOrder.length === 0) {
    const sheetId = randomId();
    sheetOrder.push(sheetId);
    sheets[sheetId] = {
      id: sheetId,
      name: "Sheet1",
      cellData: {},
      rowCount: 100,
      columnCount: 26,
    };
  }

  return {
    id,
    rev: 1,
    name: "",
    appVersion: APP_VERSION,
    locale: LocaleType.EN_US,
    styles: {},
    sheetOrder,
    sheets,
    resources: [],
  };
}

// Convert a SheetJS cell ({ v, f, t, ... }) to a Univer ICellData
// ({ v, f, t }). Returns null for empty cells.
function sheetjsCellToUniver(cell) {
  if (cell == null) return null;

  const out = {};
  let hasContent = false;

  if (cell.f) {
    out.f = "=" + cell.f.replace(/^=/, "");
    hasContent = true;
  }

  if (cell.v !== undefined && cell.v !== null) {
    out.v = cell.v;
    hasContent = true;
  } else if (cell.w !== undefined && cell.w !== null && !cell.f) {
    out.v = cell.w;
    hasContent = true;
  }

  return hasContent ? out : null;
}

// Convert the runtime Univer workbook back into raw .xlsx bytes
// (Uint8Array). We prefer reading from the Univer instance's live
// snapshot (`workbook.getSnapshot?.()` or `save?.()`); when those are
// not available, we fall back to the snapshot we mounted with, which
// will at least preserve the original load.
function snapshotToBinary(workbook, fallbackSnapshot) {
  const snapshot = readSnapshot(workbook) || fallbackSnapshot;
  if (!snapshot) {
    throw new Error("snapshotToBinary: no snapshot available on workbook");
  }

  const wb = XLSX.utils.book_new();

  for (const sheetId of snapshot.sheetOrder || []) {
    const sheetData = snapshot.sheets?.[sheetId];
    if (!sheetData) continue;

    const ws = univerSheetToSheetJs(sheetData);
    XLSX.utils.book_append_sheet(wb, ws, sheetData.name || "Sheet");
  }

  const out = XLSX.write(wb, { type: "array", bookType: "xlsx" });
  return out instanceof Uint8Array ? out : new Uint8Array(out);
}

// Try the various ways Univer exposes a workbook snapshot across 0.x.
function readSnapshot(workbook) {
  if (!workbook) return null;
  if (typeof workbook.getSnapshot === "function") {
    try { return workbook.getSnapshot(); } catch (_e) { /* fallthrough */ }
  }
  if (typeof workbook.save === "function") {
    try { return workbook.save(); } catch (_e) { /* fallthrough */ }
  }
  if (typeof workbook.toJSON === "function") {
    try { return workbook.toJSON(); } catch (_e) { /* fallthrough */ }
  }
  return null;
}

function univerSheetToSheetJs(sheetData) {
  const ws = {};
  const cellData = sheetData.cellData || {};
  let minR = Infinity, minC = Infinity, maxR = -Infinity, maxC = -Infinity;

  for (const rowKey of Object.keys(cellData)) {
    const r = parseInt(rowKey, 10);
    const row = cellData[rowKey] || {};
    for (const colKey of Object.keys(row)) {
      const c = parseInt(colKey, 10);
      const cell = row[colKey];
      if (!cell) continue;

      const sheetjsCell = univerCellToSheetJs(cell);
      if (sheetjsCell === null) continue;

      const addr = XLSX.utils.encode_cell({ r, c });
      ws[addr] = sheetjsCell;

      if (r < minR) minR = r;
      if (c < minC) minC = c;
      if (r > maxR) maxR = r;
      if (c > maxC) maxC = c;
    }
  }

  if (minR !== Infinity) {
    ws["!ref"] = XLSX.utils.encode_range({
      s: { r: minR, c: minC },
      e: { r: maxR, c: maxC },
    });
  } else {
    ws["!ref"] = "A1";
  }

  return ws;
}

function univerCellToSheetJs(cell) {
  if (!cell) return null;
  const hasFormula = typeof cell.f === "string" && cell.f.length > 0;
  const hasValue = cell.v !== undefined && cell.v !== null;
  if (!hasFormula && !hasValue) return null;

  const out = {};
  if (hasFormula) {
    out.f = cell.f.replace(/^=/, "");
  }
  if (hasValue) {
    out.v = cell.v;
    out.t = sheetjsType(cell.v);
  } else {
    // Formula without computed value: SheetJS still needs a type.
    out.t = "n";
  }

  return out;
}

function sheetjsType(value) {
  if (typeof value === "number") return "n";
  if (typeof value === "boolean") return "b";
  if (value instanceof Date) return "d";
  return "s";
}

function randomId() {
  // Univer is happy with any unique string id.
  return Math.random().toString(36).slice(2, 10);
}

// Expose the adapter on `window` so colocated hook scripts (which are
// extracted into a separate compilation unit by the Phoenix LiveView
// compiler and have no straightforward way to do relative imports) can
// reach it without round-tripping through Phoenix.LiveView events.
if (typeof window !== "undefined") {
  window.UniverAdapter = {
    initUniverFromBinary,
    exportXlsx,
    applyPatch,
    debounce,
  };
}
