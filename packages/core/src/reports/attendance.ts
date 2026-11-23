import type { UserId } from '../ids';
import type { ClassifiedDay, HolidayKind } from '../pay/classify';
import type { DateKey } from '../time/time';

/**
 * Attendance analytics.
 *
 * One `DayRecord` per person per calendar day is the unit of every report:
 * personal history, team views and executive dashboards all aggregate the
 * same records, so numbers always reconcile across levels.
 */

export interface DayRecord {
  readonly userId: UserId;
  readonly date: DateKey;
  readonly scheduled: boolean;
  readonly onLeave: boolean;
  readonly holiday?: HolidayKind;
  readonly present: boolean;
  /** Minutes after the grace period; 0 when on time. */
  readonly lateMinutes: number;
  readonly workedMinutes: number;
  readonly overtimeMinutes: number;
  readonly nightMinutes: number;
  readonly restDayMinutes: number;
  readonly holidayMinutes: number;
  readonly missedPunch: boolean;
}

export interface DayRecordInput {
  readonly userId: UserId;
  readonly date: DateKey;
  readonly scheduledStart?: string; // ISO instant; undefined = not scheduled
  readonly onLeave?: boolean;
  readonly holiday?: HolidayKind;
  /** First clock-in attributed to this date, if any. */
  readonly clockIn?: string;
  readonly classified?: ClassifiedDay;
  readonly missedPunch?: boolean;
  readonly graceMinutes?: number;
}

export function buildDayRecord(input: DayRecordInput): DayRecord {
  const grace = input.graceMinutes ?? 5;
  const scheduled = input.scheduledStart !== undefined && input.onLeave !== true;
  const present = input.clockIn !== undefined;
  const late =
    scheduled && present && input.scheduledStart !== undefined && input.clockIn !== undefined
      ? Math.round((Date.parse(input.clockIn) - Date.parse(input.scheduledStart)) / 60_000)
      : 0;
  const c = input.classified;
  return {
    userId: input.userId,
    date: input.date,
    scheduled,
    onLeave: input.onLeave === true,
    ...(input.holiday !== undefined ? { holiday: input.holiday } : {}),
    present,
    lateMinutes: late > grace ? late : 0,
    workedMinutes: c?.workedMinutes ?? 0,
    overtimeMinutes: c?.overtimeMinutes ?? 0,
    nightMinutes: c?.nightMinutes ?? 0,
    restDayMinutes: c?.restDay === true ? c.workedMinutes : 0,
    holidayMinutes: c?.holiday !== undefined ? c.workedMinutes : 0,
    missedPunch: input.missedPunch === true,
  };
}

export interface AttendanceMetrics {
  readonly headcount: number;
  readonly scheduledDays: number;
  readonly presentDays: number;
  readonly absentDays: number;
  readonly leaveDays: number;
  readonly lateDays: number;
  readonly lateMinutes: number;
  readonly missedPunches: number;
  /** present ÷ scheduled working days (leave excluded). 1 when nothing was scheduled. */
  readonly attendanceRate: number;
  /** on-time arrivals ÷ scheduled days attended. */
  readonly punctualityRate: number;
  readonly absenteeismRate: number;
  readonly averageLateMinutes: number;
  readonly workedMinutes: number;
  readonly overtimeMinutes: number;
  readonly nightMinutes: number;
  readonly restDayMinutes: number;
  readonly holidayMinutes: number;
  readonly averageWorkedPerPresentDay: number;
  /** Overtime as a share of all worked time. */
  readonly overtimeShare: number;
}

const ratio = (n: number, d: number, empty: number) => (d === 0 ? empty : n / d);

export function summarizeAttendance(records: readonly DayRecord[]): AttendanceMetrics {
  const people = new Set<string>();
  let scheduledDays = 0;
  let presentScheduled = 0;
  let presentDays = 0;
  let leaveDays = 0;
  let lateDays = 0;
  let lateMinutes = 0;
  let missed = 0;
  let worked = 0;
  let ot = 0;
  let night = 0;
  let rest = 0;
  let holiday = 0;
  for (const r of records) {
    people.add(r.userId);
    if (r.onLeave) leaveDays++;
    if (r.scheduled) {
      scheduledDays++;
      if (r.present) presentScheduled++;
      if (r.lateMinutes > 0) {
        lateDays++;
        lateMinutes += r.lateMinutes;
      }
    }
    if (r.present) presentDays++;
    if (r.missedPunch) missed++;
    worked += r.workedMinutes;
    ot += r.overtimeMinutes;
    night += r.nightMinutes;
    rest += r.restDayMinutes;
    holiday += r.holidayMinutes;
  }
  const absentDays = scheduledDays - presentScheduled;
  return {
    headcount: people.size,
    scheduledDays,
    presentDays,
    absentDays,
    leaveDays,
    lateDays,
    lateMinutes,
    missedPunches: missed,
    attendanceRate: ratio(presentScheduled, scheduledDays, 1),
    punctualityRate: ratio(presentScheduled - lateDays, presentScheduled, 1),
    absenteeismRate: ratio(absentDays, scheduledDays, 0),
    averageLateMinutes: ratio(lateMinutes, lateDays, 0),
    workedMinutes: worked,
    overtimeMinutes: ot,
    nightMinutes: night,
    restDayMinutes: rest,
    holidayMinutes: holiday,
    averageWorkedPerPresentDay: ratio(worked, presentDays, 0),
    overtimeShare: ratio(ot, worked, 0),
  };
}

/** Metrics per group (team, department, person…), sorted by group key. */
export function summarizeBy(records: readonly DayRecord[], key: (r: DayRecord) => string): { key: string; metrics: AttendanceMetrics }[] {
  const groups = new Map<string, DayRecord[]>();
  for (const r of records) {
    const k = key(r);
    const list = groups.get(k);
    if (list === undefined) groups.set(k, [r]);
    else list.push(r);
  }
  return [...groups.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([k, list]) => ({ key: k, metrics: summarizeAttendance(list) }));
}

/** Weekly trend: one metrics point per week start (inclusive 7-day windows). */
export function weeklyTrend(records: readonly DayRecord[], weekStarts: readonly DateKey[]): { weekStart: DateKey; metrics: AttendanceMetrics }[] {
  const sorted = [...weekStarts].sort();
  return sorted.map((ws, i) => {
    const next = sorted[i + 1];
    return {
      weekStart: ws,
      metrics: summarizeAttendance(records.filter((r) => r.date >= ws && (next === undefined || r.date < next))),
    };
  });
}

/** Per-date attendance rate for heatmaps (dates with nothing scheduled are omitted). */
export function dailyRates(records: readonly DayRecord[]): { date: DateKey; rate: number; scheduled: number }[] {
  return summarizeBy(records, (r) => r.date)
    .filter((g) => g.metrics.scheduledDays > 0)
    .map((g) => ({ date: g.key as DateKey, rate: g.metrics.attendanceRate, scheduled: g.metrics.scheduledDays }));
}
