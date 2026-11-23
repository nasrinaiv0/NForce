import type { UserId } from '../ids';
import { payLineFor, type ClassifiedDay, type PayLine, type PayPolicy } from '../pay/classify';
import type { DateKey } from '../time/time';
import type { TimesheetStatus } from '../timesheet/timesheet';

/**
 * Payroll preparation register.
 *
 * Turns classified days into payable hours per pay code, paying overtime only
 * where an approved OT request covers it, and lists everything that blocks a
 * period from being locked. Produces hours × multipliers — never money.
 */

export type PayrollFlag = 'timesheet_not_approved' | 'unapproved_overtime' | 'missed_punch';

export interface PayrollEmployeeInput {
  readonly userId: UserId;
  readonly name: string;
  readonly days: readonly ClassifiedDay[];
  /** Approved OT minutes per date. */
  readonly approvedOvertime: ReadonlyMap<DateKey, number>;
  readonly timesheetStatus: TimesheetStatus;
  readonly missedPunches: number;
}

export interface PayrollRow {
  readonly userId: UserId;
  readonly name: string;
  readonly lines: readonly PayLine[];
  readonly payableMinutes: number;
  readonly weightedMinutes: number;
  readonly unapprovedOvertimeMinutes: number;
  readonly flags: readonly PayrollFlag[];
}

export interface PayrollRegister {
  readonly rows: readonly PayrollRow[];
  readonly codes: readonly string[];
  readonly ready: boolean;
  readonly blockers: number;
  readonly totals: { readonly payableMinutes: number; readonly weightedMinutes: number; readonly unapprovedOvertimeMinutes: number };
}

/**
 * Keep only approved overtime. Approval is consumed in time order: daytime
 * OT before OT that ran into the night window.
 */
export function payableLines(day: ClassifiedDay, approvedMinutes: number, policy: PayPolicy): { lines: PayLine[]; unapproved: number } {
  let budget = Math.max(0, approvedMinutes);
  let unapproved = 0;
  const lines: PayLine[] = [];
  const ordered = [...day.lines].sort((a, b) => Number(a.overtime) - Number(b.overtime) || Number(a.night) - Number(b.night));
  for (const l of ordered) {
    if (!l.overtime) {
      lines.push(l);
      continue;
    }
    const paid = Math.min(budget, l.minutes);
    budget -= paid;
    unapproved += l.minutes - paid;
    if (paid > 0) lines.push(payLineFor(policy, l.dayType, true, l.night, paid));
  }
  return { lines, unapproved };
}

const merge = (lines: readonly PayLine[]): PayLine[] => {
  const m = new Map<string, PayLine>();
  for (const l of lines) {
    const prev = m.get(l.code);
    m.set(l.code, prev === undefined ? l : { ...prev, minutes: prev.minutes + l.minutes });
  }
  return [...m.values()];
};

export function buildPayrollRegister(employees: readonly PayrollEmployeeInput[], policy: PayPolicy): PayrollRegister {
  const rows = employees.map((e): PayrollRow => {
    let unapproved = 0;
    const all: PayLine[] = [];
    for (const d of e.days) {
      const r = payableLines(d, e.approvedOvertime.get(d.date) ?? 0, policy);
      unapproved += r.unapproved;
      all.push(...r.lines);
    }
    const lines = merge(all).sort((a, b) => a.code.localeCompare(b.code));
    const flags: PayrollFlag[] = [];
    if (e.timesheetStatus !== 'approved' && e.timesheetStatus !== 'locked' && e.days.length > 0) flags.push('timesheet_not_approved');
    if (unapproved > 0) flags.push('unapproved_overtime');
    if (e.missedPunches > 0) flags.push('missed_punch');
    return {
      userId: e.userId,
      name: e.name,
      lines,
      payableMinutes: lines.reduce((n, l) => n + l.minutes, 0),
      weightedMinutes: Math.round(lines.reduce((n, l) => n + l.minutes * l.multiplier, 0)),
      unapprovedOvertimeMinutes: unapproved,
      flags,
    };
  });
  const codes = [...new Set(rows.flatMap((r) => r.lines.map((l) => l.code)))].sort();
  const blockers = rows.filter((r) => r.flags.includes('timesheet_not_approved') || r.flags.includes('missed_punch')).length;
  return {
    rows,
    codes,
    ready: blockers === 0,
    blockers,
    totals: {
      payableMinutes: rows.reduce((n, r) => n + r.payableMinutes, 0),
      weightedMinutes: rows.reduce((n, r) => n + r.weightedMinutes, 0),
      unapprovedOvertimeMinutes: rows.reduce((n, r) => n + r.unapprovedOvertimeMinutes, 0),
    },
  };
}
