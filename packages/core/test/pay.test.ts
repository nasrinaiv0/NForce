import { describe, expect, it } from 'vitest';
import {
  PH_DEFAULT_PAY_POLICY,
  authorizeOvertime,
  classifySessions,
  dayTypeOf,
  isoWeekday,
  payLineFor,
  summarizePayLines,
  weightedMinutes,
  type DateKey,
  type HolidayKind,
  type PayContext,
  type WorkSession,
} from '../src';

const holidays: Record<string, HolidayKind> = { '2026-11-30': 'regular', '2026-12-08': 'special' };
const ctx = (timeZone = 'Asia/Manila', restDays = [6, 7]): PayContext => ({
  timeZone,
  policy: PH_DEFAULT_PAY_POLICY,
  isRestDay: (d) => restDays.includes(isoWeekday(d)),
  holidayOn: (d) => holidays[d],
});

// Manila is UTC+8: local HH:MM on `date` → ISO instant.
const mnl = (date: string, hh: number, mm = 0) => {
  const [y, m, d] = date.split('-').map(Number) as [number, number, number];
  return new Date(Date.UTC(y, m - 1, d, hh - 8, mm)).toISOString();
};
const session = (date: DateKey, from: [number, number], to: [number, number, number?], breaks: [[number, number], [number, number]][] = []): WorkSession => {
  const [th, tm, dayShift = 0] = to;
  const endDate = new Date(Date.parse(`${date}T00:00:00Z`) + dayShift * 86_400_000).toISOString().slice(0, 10);
  return {
    clockIn: mnl(date, from[0], from[1]),
    clockOut: mnl(endDate, th, tm),
    breaks: breaks.map(([s, e]) => ({ start: mnl(date, s[0], s[1]), end: mnl(date, e[0], e[1]) })),
    workDate: date,
    overnight: dayShift > 0,
  };
};
const lines = (s: WorkSession[], c = ctx()) => Object.fromEntries(classifySessions(s, c).flatMap((d) => d.lines.map((l) => [l.code, l.minutes])));

describe('premium multipliers (PH defaults)', () => {
  it.each([
    ['ordinary', false, false, 'REG', 1],
    ['ordinary', true, false, 'REG_OT', 1.25],
    ['ordinary', false, true, 'REG_ND', 1.1],
    ['ordinary', true, true, 'REG_OT_ND', 1.375],
    ['rest_day', false, false, 'RD', 1.3],
    ['rest_day', true, false, 'RD_OT', 1.69],
    ['rest_day', false, true, 'RD_ND', 1.43],
    ['special', true, false, 'SH_OT', 1.69],
    ['special_rest_day', false, false, 'SH_RD', 1.5],
    ['special_rest_day', true, false, 'SH_RD_OT', 1.95],
    ['regular_holiday', false, false, 'RH', 2],
    ['regular_holiday', true, false, 'RH_OT', 2.6],
    ['regular_holiday', false, true, 'RH_ND', 2.2],
    ['regular_holiday_rest_day', false, false, 'RH_RD', 2.6],
    ['regular_holiday_rest_day', true, false, 'RH_RD_OT', 3.38],
  ] as const)('%s ot=%s nd=%s → %s ×%s', (dayType, ot, nd, code, mult) => {
    const l = payLineFor(PH_DEFAULT_PAY_POLICY, dayType, ot, nd, 60);
    expect(l.code).toBe(code);
    expect(l.multiplier).toBe(mult);
  });

  it('derives day types from rest days and holidays', () => {
    expect(dayTypeOf(false, undefined)).toBe('ordinary');
    expect(dayTypeOf(true, 'special')).toBe('special_rest_day');
    expect(dayTypeOf(true, 'regular')).toBe('regular_holiday_rest_day');
  });
});

describe('classifySessions', () => {
  it('splits an ordinary day with overtime', () => {
    // Mon 09:00–20:30, lunch 12:00–13:00 → 10h30 worked.
    expect(lines([session('2026-11-16', [9, 0], [20, 30], [[[12, 0], [13, 0]]])])).toEqual({ REG: 480, REG_OT: 150 });
  });

  it('applies night differential to a graveyard shift crossing midnight', () => {
    // Tue 22:00 → Wed 07:00, break 02:00–03:00 (on the next day).
    const s: WorkSession = {
      clockIn: mnl('2026-11-17', 22),
      clockOut: mnl('2026-11-18', 7),
      breaks: [{ start: mnl('2026-11-18', 2), end: mnl('2026-11-18', 3) }],
      workDate: '2026-11-17',
      overnight: true,
    };
    const [day] = classifySessions([s], ctx());
    expect(day?.lines.map((l) => [l.code, l.minutes])).toEqual([
      ['REG', 60],
      ['REG_ND', 420],
    ]);
    expect(day?.nightMinutes).toBe(420);
  });

  it('marks overtime that runs into the night window', () => {
    expect(lines([session('2026-11-19', [13, 0], [23, 30])])).toEqual({ REG: 480, REG_OT: 60, REG_OT_ND: 90 });
  });

  it('classifies rest-day work and rest-day overtime', () => {
    // Saturday 09:00–20:00 with a 1h break → 10h.
    expect(lines([session('2026-11-21', [9, 0], [20, 0], [[[12, 0], [13, 0]]])])).toEqual({ RD: 480, RD_OT: 120 });
  });

  it('classifies regular holidays and special days on rest days', () => {
    expect(lines([session('2026-11-30', [9, 0], [18, 0], [[[12, 0], [13, 0]]])])).toEqual({ RH: 480 });
    // Treat Tuesday as a rest day: 2026-12-08 special + rest day.
    const c = ctx('Asia/Manila', [2]);
    const [day] = classifySessions([session('2026-12-08', [9, 0], [19, 0])], c);
    expect(day?.dayType).toBe('special_rest_day');
    expect(day?.lines.map((l) => [l.code, l.minutes, l.multiplier])).toEqual([
      ['SH_RD', 480, 1.5],
      ['SH_RD_OT', 120, 1.95],
    ]);
  });

  it('counts overtime across split shifts on the same day', () => {
    const morning = session('2026-11-20', [6, 0], [11, 0]);
    const evening = session('2026-11-20', [15, 0], [20, 0]);
    // 06:00–11:00 (5h) + 15:00–20:00 (5h) = 10h; the 8h threshold is crossed at 18:00.
    expect(lines([evening, morning])).toEqual({ REG: 480, REG_OT: 120 });
  });

  it('ignores open sessions and handles DST fall-back by elapsed time', () => {
    const open: WorkSession = { clockIn: mnl('2026-11-16', 9), breaks: [], workDate: '2026-11-16', overnight: false };
    expect(classifySessions([open], ctx())).toEqual([]);
    // New York 2026-11-01: 00:00 EDT (04:00Z) → 08:00 EST (13:00Z) = 9h, 01:00 occurs twice.
    const ny: WorkSession = { clockIn: '2026-11-01T04:00:00Z', clockOut: '2026-11-01T13:00:00Z', breaks: [], workDate: '2026-11-01', overnight: false };
    const [day] = classifySessions([ny], ctx('America/New_York', []));
    expect(day?.workedMinutes).toBe(540);
    expect(day?.nightMinutes).toBe(7 * 60); // 00:00–06:00 local spans 7 real hours
  });

  it('summarizes by code and weights by multiplier', () => {
    const days = classifySessions(
      [session('2026-11-16', [9, 0], [20, 30], [[[12, 0], [13, 0]]]), session('2026-11-21', [9, 0], [20, 0], [[[12, 0], [13, 0]]])],
      ctx(),
    );
    expect(summarizePayLines(days).map((l) => l.code)).toEqual(['REG', 'REG_OT', 'RD', 'RD_OT']);
    expect(weightedMinutes(summarizePayLines(days))).toBe(Math.round(480 + 150 * 1.25 + 480 * 1.3 + 120 * 1.69));
  });

  it('treats overtime below the minimum block as excess time, not OT', () => {
    // 09:00–18:20 with a 1h lunch → 8h20: 20 min past regular hours.
    const [day] = classifySessions([session('2026-11-16', [9, 0], [18, 20], [[[12, 0], [13, 0]]])], ctx());
    expect(day?.lines.map((l) => [l.code, l.minutes])).toEqual([['REG', 480]]);
    expect(day?.excessMinutes).toBe(20);
    expect(day?.overtimeMinutes).toBe(0);
    // Exactly the minimum counts as OT; a policy of 0 counts every minute.
    expect(lines([session('2026-11-16', [9, 0], [18, 30], [[[12, 0], [13, 0]]])])).toEqual({ REG: 480, REG_OT: 30 });
    const everyMinute = { ...ctx(), policy: { ...PH_DEFAULT_PAY_POLICY, minimumOvertimeMinutes: 0 } };
    expect(lines([session('2026-11-16', [9, 0], [18, 20], [[[12, 0], [13, 0]]])], everyMinute)).toEqual({ REG: 480, REG_OT: 20 });
  });

  it('separates approved from unapproved overtime', () => {
    const [day] = classifySessions([session('2026-11-16', [9, 0], [20, 30], [[[12, 0], [13, 0]]])], ctx());
    expect(authorizeOvertime(day!, 60)).toEqual({ overtimeMinutes: 150, approvedMinutes: 60, unapprovedMinutes: 90 });
    expect(authorizeOvertime(day!, 500).unapprovedMinutes).toBe(0);
    expect(authorizeOvertime(day!, -5).approvedMinutes).toBe(0);
  });
});
