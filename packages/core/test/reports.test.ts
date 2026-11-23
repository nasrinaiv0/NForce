import { describe, expect, it } from 'vitest';
import {
  PH_DEFAULT_PAY_POLICY,
  UserId,
  approvalSla,
  buildDayRecord,
  buildPayrollRegister,
  csvCell,
  dailyRates,
  isClosed,
  moveDeal,
  payLineFor,
  payableLines,
  percentile,
  pipelineSummary,
  summarizeAttendance,
  summarizeBy,
  toCsv,
  weeklyTrend,
  type ClassifiedDay,
  type Deal,
} from '../src';

const A = UserId('a');
const B = UserId('b');
const start = (d: string, hh: number, mm = 0) => new Date(Date.UTC(2026, 10, Number(d.slice(8)), hh - 8, mm)).toISOString();
const day = (minutes: number, ot = 0, night = 0): ClassifiedDay => ({
  date: '2026-11-16',
  dayType: 'ordinary',
  restDay: false,
  workedMinutes: minutes,
  regularMinutes: minutes - ot,
  overtimeMinutes: ot,
  nightMinutes: night,
  excessMinutes: 0,
  lines: [
    payLineFor(PH_DEFAULT_PAY_POLICY, 'ordinary', false, false, minutes - ot),
    ...(ot - night > 0 ? [payLineFor(PH_DEFAULT_PAY_POLICY, 'ordinary', true, false, ot - night)] : []),
    ...(night > 0 ? [payLineFor(PH_DEFAULT_PAY_POLICY, 'ordinary', true, true, night)] : []),
  ],
});

describe('attendance records and metrics', () => {
  const records = [
    buildDayRecord({ userId: A, date: '2026-11-16', scheduledStart: start('2026-11-16', 9), clockIn: start('2026-11-16', 9, 3), classified: day(480) }),
    buildDayRecord({ userId: A, date: '2026-11-17', scheduledStart: start('2026-11-17', 9), clockIn: start('2026-11-17', 9, 20), classified: day(600, 120) }),
    buildDayRecord({ userId: B, date: '2026-11-16', scheduledStart: start('2026-11-16', 9) }), // absent
    buildDayRecord({ userId: B, date: '2026-11-17', scheduledStart: start('2026-11-17', 9), onLeave: true }),
    buildDayRecord({ userId: B, date: '2026-11-21', clockIn: start('2026-11-21', 9), classified: { ...day(300), date: '2026-11-21', restDay: true } }),
  ];

  it('applies the grace period and leave correctly', () => {
    expect(records[0]?.lateMinutes).toBe(0);
    expect(records[1]?.lateMinutes).toBe(20);
    expect(records[3]?.scheduled).toBe(false); // leave is not an absence
  });

  it('summarizes rates that reconcile', () => {
    const m = summarizeAttendance(records);
    expect(m).toMatchObject({ headcount: 2, scheduledDays: 3, presentDays: 3, absentDays: 1, leaveDays: 1, lateDays: 1, lateMinutes: 20 });
    expect(m.attendanceRate).toBeCloseTo(2 / 3);
    expect(m.punctualityRate).toBeCloseTo(1 / 2);
    expect(m.absenteeismRate).toBeCloseTo(1 / 3);
    expect(m.overtimeShare).toBeCloseTo(120 / 1380);
    expect(m.restDayMinutes).toBe(300);
    expect(summarizeAttendance([])).toMatchObject({ attendanceRate: 1, punctualityRate: 1, absenteeismRate: 0, averageWorkedPerPresentDay: 0 });
  });

  it('groups, trends and heatmaps from the same records', () => {
    expect(summarizeBy(records, (r) => r.userId).map((g) => [g.key, g.metrics.presentDays])).toEqual([['a', 2], ['b', 1]]);
    const trend = weeklyTrend(records, ['2026-11-16', '2026-11-09']);
    expect(trend.map((t) => [t.weekStart, t.metrics.scheduledDays])).toEqual([['2026-11-09', 0], ['2026-11-16', 3]]);
    expect(dailyRates(records)).toEqual([
      { date: '2026-11-16', rate: 0.5, scheduled: 2 },
      { date: '2026-11-17', rate: 1, scheduled: 1 },
    ]);
  });
});

describe('approval SLA', () => {
  it('computes turnaround percentiles and overdue items', () => {
    const now = new Date('2026-11-23T00:00:00Z');
    const sla = approvalSla(
      [
        { kind: 'leave', submittedAt: '2026-11-20T00:00:00Z', decidedAt: '2026-11-20T02:00:00Z', status: 'approved' },
        { kind: 'leave', submittedAt: '2026-11-20T00:00:00Z', decidedAt: '2026-11-21T00:00:00Z', status: 'returned' },
        { kind: 'overtime', submittedAt: '2026-11-19T00:00:00Z', status: 'pending' },
        { kind: 'overtime', submittedAt: '2026-11-22T12:00:00Z', status: 'pending' },
      ],
      now,
    );
    expect(sla).toMatchObject({ total: 4, pending: 2, approved: 1, returned: 1, approvalRate: 0.5, medianHoursToDecide: 2, p90HoursToDecide: 24, overdue: 1 });
    expect(sla.byKind).toEqual([{ kind: 'leave', total: 2, pending: 0 }, { kind: 'overtime', total: 2, pending: 2 }]);
    expect(percentile([], 50)).toBe(0);
    expect(approvalSla([], now).approvalRate).toBe(1);
  });
});

describe('CSV export', () => {
  it('quotes, escapes and neutralizes formulas', () => {
    expect(csvCell('plain')).toBe('plain');
    expect(csvCell('a,b')).toBe('"a,b"');
    expect(csvCell('say "hi"')).toBe('"say ""hi"""');
    expect(csvCell('line\nbreak')).toBe('"line\nbreak"');
    expect(csvCell('=HYPERLINK("x")')).toBe(`"'=HYPERLINK(""x"")"`);
    expect(csvCell('-5 minus')).toBe("'-5 minus");
    expect(csvCell(-5)).toBe('-5');
    expect(csvCell(Number.NaN)).toBe('');
    expect(csvCell(null)).toBe('');
    expect(csvCell(true)).toBe('true');
    const csv = toCsv([{ n: 'Ana', h: 8 }], [{ header: 'Name', value: (r) => r.n }, { header: 'Hours', value: (r) => r.h }], { bom: true });
    expect(csv).toBe('﻿Name,Hours\r\nAna,8\r\n');
  });
});

describe('payroll register', () => {
  it('pays only approved overtime, daytime OT first', () => {
    const d = day(660, 180, 60); // 3h OT of which 1h at night
    expect(payableLines(d, 150, PH_DEFAULT_PAY_POLICY)).toEqual({
      lines: [d.lines[0], d.lines[1], payLineFor(PH_DEFAULT_PAY_POLICY, 'ordinary', true, true, 30)],
      unapproved: 30,
    });
    expect(payableLines(d, 0, PH_DEFAULT_PAY_POLICY).unapproved).toBe(180);
  });

  it('flags blockers and totals hours', () => {
    const reg = buildPayrollRegister(
      [
        { userId: A, name: 'Ana', days: [day(540, 60)], approvedOvertime: new Map([['2026-11-16', 60]]), timesheetStatus: 'approved', missedPunches: 0 },
        { userId: B, name: 'Ben', days: [day(540, 60)], approvedOvertime: new Map(), timesheetStatus: 'submitted', missedPunches: 1 },
      ],
      PH_DEFAULT_PAY_POLICY,
    );
    expect(reg.rows[0]).toMatchObject({ payableMinutes: 540, weightedMinutes: 480 + 75, flags: [] });
    expect(reg.rows[1]).toMatchObject({ payableMinutes: 480, unapprovedOvertimeMinutes: 60, flags: ['timesheet_not_approved', 'unapproved_overtime', 'missed_punch'] });
    expect(reg).toMatchObject({ ready: false, blockers: 1, codes: ['REG', 'REG_OT'] });
    expect(reg.totals.unapprovedOvertimeMinutes).toBe(60);
    expect(buildPayrollRegister([], PH_DEFAULT_PAY_POLICY).ready).toBe(true);
  });
});

describe('CRM pipeline', () => {
  const deal: Deal = { id: 'd1', name: 'Renewal', account: 'Acme', ownerName: 'Ana', stage: 'proposal', amountMinor: 100_000_00, currency: 'PHP', closeDate: '2026-12-15' };

  it('moves open deals and protects closed ones', () => {
    expect(moveDeal(deal, 'negotiation')).toMatchObject({ ok: true, value: { stage: 'negotiation' } });
    expect(moveDeal(deal, 'lost')).toMatchObject({ ok: false, error: { code: 'reason_required' } });
    expect(moveDeal({ ...deal, stage: 'won' }, 'proposal')).toMatchObject({ ok: false, error: { code: 'closed_deal' } });
    expect(moveDeal(deal, 'nope' as never)).toMatchObject({ ok: false, error: { code: 'unknown_stage' } });
    expect(isClosed('lost')).toBe(true);
  });

  it('forecasts weighted pipeline value in minor units', () => {
    const s = pipelineSummary([deal, { ...deal, id: 'd2', stage: 'won', amountMinor: 50_000_00 }, { ...deal, id: 'd3', stage: 'lost' }]);
    expect(s.openAmountMinor).toBe(100_000_00);
    expect(s.weightedForecastMinor).toBe(50_000_00);
    expect(s.wonAmountMinor).toBe(50_000_00);
    expect(s.winRate).toBe(0.5);
    expect(pipelineSummary([]).winRate).toBe(0);
  });
});
