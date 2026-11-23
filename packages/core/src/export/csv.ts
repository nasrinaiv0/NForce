/**
 * RFC 4180 CSV export, safe to open in spreadsheet apps.
 *
 * - Fields containing comma, quote, CR or LF are quoted; quotes are doubled.
 * - Formula injection (CWE-1236) is neutralized: text cells starting with
 *   = + - @ TAB or CR are prefixed with an apostrophe. Numbers are untouched.
 * - CRLF line endings and an optional UTF-8 BOM for Excel.
 */

export interface CsvColumn<T> {
  readonly header: string;
  readonly value: (row: T) => string | number | boolean | null | undefined;
}

const FORMULA_START = /^[=+\-@\t\r]/;

export function csvCell(value: string | number | boolean | null | undefined): string {
  if (value === null || value === undefined) return '';
  if (typeof value === 'number') return Number.isFinite(value) ? String(value) : '';
  let text = typeof value === 'boolean' ? (value ? 'true' : 'false') : value;
  if (FORMULA_START.test(text)) text = `'${text}`;
  return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

export function toCsv<T>(rows: readonly T[], columns: readonly CsvColumn<T>[], options: { bom?: boolean } = {}): string {
  const lines = [columns.map((c) => csvCell(c.header)).join(','), ...rows.map((r) => columns.map((c) => csvCell(c.value(r))).join(','))];
  return `${options.bom === true ? '﻿' : ''}${lines.join('\r\n')}\r\n`;
}
