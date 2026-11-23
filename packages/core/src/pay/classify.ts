import type { WorkSession } from '../attendance/attendance';
import { zonedParts, type DateKey } from '../time/time';

/**
 * Pay-category classification (hours, not money).
 *
 * Splits worked minutes into premium categories that payroll multiplies by an
 * hourly rate: regular, overtime (OT), night differential (ND), rest day (RD),
 * special non-working day (SH), regular holiday (RH), and every combination
 * (e.g. RD_OT_ND = rest-day overtime worked at night).
 *
 * The default policy encodes the commonly published Philippine Labor Code
 * premiums (DOLE Handbook on Workers' Statutory Monetary Benefits). Policies
 * are data: other jurisdictions and CBAs configure their own. Payroll must
 * validate the policy with qualified professionals before production use.
 *
 * Attribution: a shift belongs to the calendar day it STARTED on (in the
 * organization's zone), so an overnight shift is classified with the day type
 * of its start date. Partial minutes are not counted. Overtime shorter than
 * the policy's minimum block is reported as excess time, not OT.
 */

export type HolidayKind = 'regular' | 'special';

export type DayType =
  | 'ordinary'
  | 'rest_day'
  | 'special'
  | 'special_rest_day'
  | 'regular_holiday'
  | 'regular_holiday_rest_day';

export const DAY_TYPES: readonly DayType[] = [
  'ordinary',
  'rest_day',
  'special',
  'special_rest_day',
  'regular_holiday',
  'regular_holiday_rest_day',
];

export interface PayPolicy {
  readonly id: string;
  readonly name: string;
  /** Minutes per day paid at the day rate before overtime starts. */
  readonly regularDailyMinutes: number;
  /** Night window in local minutes after midnight; may wrap past midnight. */
  readonly nightStartMinute: number;
  readonly nightEndMinute: number;
  /** Rate for the first `regularDailyMinutes` of each day type (1 = 100%). */
  readonly dayRate: Readonly<Record<DayType, number>>;
  /** Overtime factor applied on top of the day rate. */
  readonly overtimeFactor: Readonly<Record<DayType, number>>;
  /** Night-differential factor applied on top of the (overtime) rate. */
  readonly nightFactor: number;
  /**
   * Company rule: overtime below this many minutes on a day is recorded as
   * excess time (not paid as OT, not needing approval). 0 counts every minute.
   */
  readonly minimumOvertimeMinutes: number;
}

/**
 * Philippine defaults: ordinary OT +25%; work on rest/special days +30%;
 * special day on a rest day +50%; regular holiday 200%; regular holiday on a
 * rest day 260%; OT on non-ordinary days +30% of that day's rate; night shift
 * differential +10% for work between 22:00 and 06:00.
 */
export const PH_DEFAULT_PAY_POLICY: PayPolicy = {
  id: 'ph-labor-code-default',
  name: 'Philippines · Labor Code defaults',
  regularDailyMinutes: 8 * 60,
  nightStartMinute: 22 * 60,
  nightEndMinute: 6 * 60,
  dayRate: {
    ordinary: 1,
    rest_day: 1.3,
    special: 1.3,
    special_rest_day: 1.5,
    regular_holiday: 2,
    regular_holiday_rest_day: 2.6,
  },
  overtimeFactor: {
    ordinary: 1.25,
    rest_day: 1.3,
    special: 1.3,
    special_rest_day: 1.3,
    regular_holiday: 1.3,
    regular_holiday_rest_day: 1.3,
  },
  nightFactor: 1.1,
  minimumOvertimeMinutes: 30,
};

const DAY_CODE: Readonly<Record<DayType, string>> = {
  ordinary: 'REG',
  rest_day: 'RD',
  special: 'SH',
  special_rest_day: 'SH_RD',
  regular_holiday: 'RH',
  regular_holiday_rest_day: 'RH_RD',
};

export interface PayLine {
  /** Stable payroll code, e.g. `REG`, `REG_OT`, `RD_OT_ND`, `RH_ND`. */
  readonly code: string;
  readonly dayType: DayType;
  readonly overtime: boolean;
  readonly night: boolean;
  readonly minutes: number;
  /** Multiplier of the basic hourly rate (e.g. 1.69 for rest-day OT). */
  readonly multiplier: number;
}

export interface ClassifiedDay {
  readonly date: DateKey;
  readonly dayType: DayType;
  readonly holiday?: HolidayKind;
  readonly restDay: boolean;
  readonly workedMinutes: number;
  readonly regularMinutes: number;
  readonly overtimeMinutes: number;
  readonly nightMinutes: number;
  /** Time past regular hours below the OT minimum: recorded, not paid as OT. */
  readonly excessMinutes: number;
  readonly lines: readonly PayLine[];
}

export interface PayContext {
  readonly timeZone: string;
  readonly policy: PayPolicy;
  readonly isRestDay: (date: DateKey) => boolean;
  readonly holidayOn: (date: DateKey) => HolidayKind | undefined;
}

export function dayTypeOf(restDay: boolean, holiday: HolidayKind | undefined): DayType {
  if (holiday === 'regular') return restDay ? 'regular_holiday_rest_day' : 'regular_holiday';
  if (holiday === 'special') return restDay ? 'special_rest_day' : 'special';
  return restDay ? 'rest_day' : 'ordinary';
}

const round4 = (n: number) => Math.round(n * 10_000) / 10_000;

export function payLineFor(policy: PayPolicy, dayType: DayType, overtime: boolean, night: boolean, minutes: number): PayLine {
  const multiplier = round4(
    policy.dayRate[dayType] * (overtime ? policy.overtimeFactor[dayType] : 1) * (night ? policy.nightFactor : 1),
  );
  const code = `${DAY_CODE[dayType]}${overtime ? '_OT' : ''}${night ? '_ND' : ''}`;
  return { code, dayType, overtime, night, minutes, multiplier };
}

const MINUTE = 60_000;

/** Worked intervals of a closed session: [clockIn, clockOut] minus breaks. */
function workedIntervals(session: WorkSession): [number, number][] {
  if (session.clockOut === undefined) return [];
  const start = Date.parse(session.clockIn);
  const end = Date.parse(session.clockOut);
  const breaks = session.breaks
    .map((b): [number, number] => [Math.max(start, Date.parse(b.start)), Math.min(end, Date.parse(b.end ?? session.clockOut ?? b.start))])
    .filter(([a, b]) => b > a)
    .sort((a, b) => a[0] - b[0]);
  const out: [number, number][] = [];
  let cursor = start;
  for (const [a, b] of breaks) {
    if (a > cursor) out.push([cursor, a]);
    cursor = Math.max(cursor, b);
  }
  if (end > cursor) out.push([cursor, end]);
  return out;
}

function isNightMinute(localMinute: number, policy: PayPolicy): boolean {
  const { nightStartMinute: s, nightEndMinute: e } = policy;
  return s <= e ? localMinute >= s && localMinute < e : localMinute >= s || localMinute < e;
}

/** UTC offset (minutes) of `ms` in `timeZone`. */
function offsetMinutes(ms: number, timeZone: string): number {
  const p = zonedParts(new Date(ms), timeZone);
  return Math.round((Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute) - Math.floor(ms / MINUTE) * MINUTE) / MINUTE);
}

/**
 * Classify closed sessions into pay lines per work date. Open sessions are
 * ignored (they are not payable until closed).
 */
export function classifySessions(sessions: readonly WorkSession[], ctx: PayContext): ClassifiedDay[] {
  const byDate = new Map<DateKey, WorkSession[]>();
  for (const s of sessions) {
    if (s.clockOut === undefined) continue;
    const list = byDate.get(s.workDate);
    if (list === undefined) byDate.set(s.workDate, [s]);
    else list.push(s);
  }

  return [...byDate.keys()].sort().map((date) => {
    const restDay = ctx.isRestDay(date);
    const holiday = ctx.holidayOn(date);
    const dayType = dayTypeOf(restDay, holiday);
    const counts = new Map<string, { overtime: boolean; night: boolean; minutes: number }>();
    let worked = 0;

    const intervals = (byDate.get(date) ?? [])
      .flatMap(workedIntervals)
      .sort((a, b) => a[0] - b[0]);
    for (const [start, end] of intervals) {
      const minutes = Math.floor((end - start) / MINUTE);
      let offset = offsetMinutes(start, ctx.timeZone);
      for (let i = 0; i < minutes; i++) {
        const ms = start + i * MINUTE;
        const utcMinute = Math.floor(ms / MINUTE);
        // Offsets only change on :00/:30 boundaries; re-sample there.
        if (i > 0 && utcMinute % 30 === 0) offset = offsetMinutes(ms, ctx.timeZone);
        const local = (((utcMinute + offset) % 1440) + 1440) % 1440;
        const overtime = worked >= ctx.policy.regularDailyMinutes;
        const night = isNightMinute(local, ctx.policy);
        const key = `${overtime ? 1 : 0}${night ? 1 : 0}`;
        const bucket = counts.get(key);
        if (bucket === undefined) counts.set(key, { overtime, night, minutes: 1 });
        else bucket.minutes++;
        worked++;
      }
    }

    const otTotal = (counts.get('10')?.minutes ?? 0) + (counts.get('11')?.minutes ?? 0);
    const excessMinutes = otTotal > 0 && otTotal < ctx.policy.minimumOvertimeMinutes ? otTotal : 0;
    if (excessMinutes > 0) {
      counts.delete('10');
      counts.delete('11');
    }
    const lines = ['00', '01', '10', '11'].flatMap((k) => {
      const b = counts.get(k);
      return b === undefined ? [] : [payLineFor(ctx.policy, dayType, b.overtime, b.night, b.minutes)];
    });
    const sum = (f: (l: PayLine) => boolean) => lines.filter(f).reduce((n, l) => n + l.minutes, 0);
    return {
      date,
      dayType,
      ...(holiday !== undefined ? { holiday } : {}),
      restDay,
      workedMinutes: worked,
      regularMinutes: sum((l) => !l.overtime),
      overtimeMinutes: sum((l) => l.overtime),
      nightMinutes: sum((l) => l.night),
      excessMinutes,
      lines,
    };
  });
}

/** Aggregate pay lines across days by code, in a stable, payroll-friendly order. */
export function summarizePayLines(days: readonly ClassifiedDay[]): PayLine[] {
  const totals = new Map<string, PayLine>();
  for (const line of days.flatMap((d) => d.lines)) {
    const prev = totals.get(line.code);
    totals.set(line.code, prev === undefined ? line : { ...prev, minutes: prev.minutes + line.minutes });
  }
  const rank = (l: PayLine) => DAY_TYPES.indexOf(l.dayType) * 4 + (l.overtime ? 2 : 0) + (l.night ? 1 : 0);
  return [...totals.values()].sort((a, b) => rank(a) - rank(b));
}

/** Equivalent paid hours (minutes × multiplier), useful for quick totals. */
export const weightedMinutes = (lines: readonly PayLine[]): number =>
  Math.round(lines.reduce((sum, l) => sum + l.minutes * l.multiplier, 0));

export interface OvertimeAuthorization {
  readonly overtimeMinutes: number;
  readonly approvedMinutes: number;
  /** OT worked but not covered by an approved OT request. */
  readonly unapprovedMinutes: number;
}

/** Compare OT worked on a day with the minutes approved for that day. */
export function authorizeOvertime(day: ClassifiedDay, approvedMinutes: number): OvertimeAuthorization {
  const approved = Math.min(day.overtimeMinutes, Math.max(0, approvedMinutes));
  return { overtimeMinutes: day.overtimeMinutes, approvedMinutes: approved, unapprovedMinutes: day.overtimeMinutes - approved };
}
