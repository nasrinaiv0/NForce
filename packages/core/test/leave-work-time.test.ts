import { describe, expect, it } from 'vitest';
import {
  addDays,
  assertNever,
  countWorkingDays,
  dateRange,
  daysBetween,
  evaluateTimeOff,
  formatClock,
  formatDuration,
  groupTasks,
  isDateKey,
  isoWeekday,
  localDateKey,
  minutesBetween,
  parseDateKey,
  type LeavePolicy,
  type Task,
} from '../src';
import { ALICE, BOB, ORG } from './fixtures';

const vacation: LeavePolicy = {
  leaveTypeId: 'vacation',
  name: 'Vacation',
  nonWorkingWeekdays: [6, 7],
  allowHalfDays: true,
  minNoticeDays: 3,
  maxConsecutiveDays: 15,
  allowNegativeBalance: false,
};
const base = { organizationId: ORG, userId: ALICE };
const ctx = { today: '2026-11-23' as const, existing: [], policy: vacation, availableBalance: 5 };

describe('time off', () => {
  it('counts working days, excluding weekends', () => {
    // Mon 2026-11-30 … Sun 2026-12-06
    expect(countWorkingDays('2026-11-30', '2026-12-06', [6, 7])).toBe(5);
  });

  it('deducts leave balance by working days', () => {
    const r = evaluateTimeOff({ ...base, kind: 'leave', leaveTypeId: 'vacation', start: '2026-11-30', end: '2026-12-02' }, ctx);
    expect(r).toEqual({ ok: true, value: { days: 3, balanceImpact: 3, balanceAfter: 2 } });
  });

  it('never deducts balance for day-off (roster) requests', () => {
    const r = evaluateTimeOff({ ...base, kind: 'day_off', start: '2026-11-24', end: '2026-11-25' }, { ...ctx, availableBalance: 0 });
    expect(r).toEqual({ ok: true, value: { days: 2, balanceImpact: 0 } });
  });

  it('supports half days only for single dates', () => {
    const one = { ...base, kind: 'leave' as const, leaveTypeId: 'vacation', start: '2026-11-30' as const, end: '2026-11-30' as const, halfDay: 'am' as const };
    expect(evaluateTimeOff(one, ctx)).toMatchObject({ ok: true, value: { days: 0.5 } });
    expect(evaluateTimeOff({ ...one, end: '2026-12-01' }, ctx)).toMatchObject({ ok: false, error: { code: 'half_day_not_allowed' } });
  });

  it.each([
    ['invalid_range', { start: '2026-12-02', end: '2026-12-01' }, {}],
    ['invalid_range', { start: '2026-11-20', end: '2026-11-20' }, {}],
    ['insufficient_notice', { start: '2026-11-24', end: '2026-11-24' }, {}],
    ['too_long', { start: '2026-12-01', end: '2026-12-31' }, {}],
    ['no_working_days', { start: '2026-12-05', end: '2026-12-06' }, {}],
    ['insufficient_balance', { start: '2026-11-30', end: '2026-12-11' }, {}],
    ['overlap', { start: '2026-12-01', end: '2026-12-01' }, { existing: [{ start: '2026-11-30', end: '2026-12-02' }] }],
    ['policy_mismatch', { start: '2026-12-01', end: '2026-12-01' }, { policy: { ...vacation, leaveTypeId: 'sick' } }],
  ] as const)('rejects with %s', (code, range, extra) => {
    const r = evaluateTimeOff({ ...base, kind: 'leave', leaveTypeId: 'vacation', ...range }, { ...ctx, ...extra });
    expect(r).toMatchObject({ ok: false, error: { code } });
  });

  it('allows negative balance when policy permits', () => {
    const r = evaluateTimeOff(
      { ...base, kind: 'leave', leaveTypeId: 'vacation', start: '2026-11-30', end: '2026-12-01' },
      { ...ctx, availableBalance: 1, policy: { ...vacation, allowNegativeBalance: true } },
    );
    expect(r).toMatchObject({ ok: true, value: { balanceAfter: -1 } });
  });
});

describe('work center grouping', () => {
  const t = (id: string, extra: Partial<Task>): Task => ({
    id,
    title: id,
    status: 'todo',
    priority: 'normal',
    assigneeId: ALICE,
    createdById: BOB,
    ...extra,
  });

  it('buckets and sorts by priority then due date', () => {
    const groups = groupTasks(
      [
        t('late', { due: '2026-11-20' }),
        t('today-low', { due: '2026-11-23', priority: 'low' }),
        t('today-urgent', { due: '2026-11-23', priority: 'urgent' }),
        t('later', { due: '2026-12-01' }),
        t('whenever', {}),
        t('finished', { status: 'done', due: '2026-11-01' }),
      ],
      '2026-11-23',
    );
    expect(groups.map((g) => g.bucket)).toEqual(['overdue', 'today', 'upcoming', 'someday', 'done']);
    expect(groups[1]?.tasks.map((x) => x.id)).toEqual(['today-urgent', 'today-low']);
  });
});

describe('time utilities', () => {
  it('derives calendar dates in an explicit zone', () => {
    const instant = new Date('2026-11-22T17:30:00Z');
    expect(localDateKey(instant, 'Asia/Manila')).toBe('2026-11-23');
    expect(localDateKey(instant, 'America/New_York')).toBe('2026-11-22');
  });

  it('handles DST boundaries by calendar date, not 24h arithmetic', () => {
    // US DST ended 2026-11-01.
    expect(addDays('2026-10-31', 1)).toBe('2026-11-01');
    expect(daysBetween('2026-10-31', '2026-11-02')).toBe(2);
    expect(localDateKey(new Date('2026-11-01T05:30:00Z'), 'America/New_York')).toBe('2026-11-01');
  });

  it('validates date keys strictly', () => {
    expect(isDateKey('2026-02-29')).toBe(false);
    expect(isDateKey('2028-02-29')).toBe(true);
    expect(isDateKey('2026-1-01')).toBe(false);
    expect(() => parseDateKey('nope')).toThrow(RangeError);
  });

  it('computes ranges and weekdays', () => {
    expect(dateRange('2026-11-29', '2026-12-01')).toEqual(['2026-11-29', '2026-11-30', '2026-12-01']);
    expect(dateRange('2026-12-01', '2026-11-29')).toEqual([]);
    expect(isoWeekday('2026-11-23')).toBe(1);
    expect(isoWeekday('2026-11-29')).toBe(7);
    expect(minutesBetween('2026-11-23T00:00:00Z', '2026-11-23T01:30:59Z')).toBe(90);
  });

  it('formats durations and clocks', () => {
    expect(formatDuration(45)).toBe('45m');
    expect(formatDuration(425)).toBe('7h 05m');
    expect(formatDuration(-90)).toBe('-1h 30m');
    expect(formatClock(3723)).toBe('01:02:03');
    expect(formatClock(-5)).toBe('00:00:00');
  });

  it('assertNever throws for unhandled variants', () => {
    expect(() => assertNever('x' as never)).toThrow('Unhandled value');
  });
});

describe('instantFromZoned', () => {
  it('converts wall-clock times in fixed and DST zones', async () => {
    const { instantFromZoned } = await import('../src');
    expect(instantFromZoned('2026-11-23', 9, 0, 'Asia/Manila').toISOString()).toBe('2026-11-23T01:00:00.000Z');
    expect(instantFromZoned('2026-07-01', 9, 30, 'America/New_York').toISOString()).toBe('2026-07-01T13:30:00.000Z');
    expect(instantFromZoned('2026-12-01', 9, 30, 'America/New_York').toISOString()).toBe('2026-12-01T14:30:00.000Z');
    // Spring-forward gap (02:30 does not exist on 2026-03-08 in New York).
    const gap = instantFromZoned('2026-03-08', 2, 30, 'America/New_York');
    expect(gap.toISOString()).toBe('2026-03-08T07:30:00.000Z');
  });
});
