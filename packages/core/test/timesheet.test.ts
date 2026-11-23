import { describe, expect, it } from 'vitest';
import {
  adjustLockedTimesheet,
  availableTimesheetActions,
  timesheetTotalMinutes,
  transitionTimesheet,
  type Timesheet,
} from '../src';
import { ALICE, BOB, ORG, TEAM_A, subject } from './fixtures';

const alice = subject(ALICE, ['staff']);
const bob = subject(BOB, ['supervisor']);
const payroll = subject(BOB, ['payroll']);

const sheet: Timesheet = {
  id: 'ts1',
  organizationId: ORG,
  userId: ALICE,
  teamId: TEAM_A,
  periodStart: '2026-11-16',
  periodEnd: '2026-11-22',
  status: 'draft',
  entries: [
    { date: '2026-11-16', workedMinutes: 480, breakMinutes: 60 },
    { date: '2026-11-17', workedMinutes: 450, breakMinutes: 60 },
  ],
  adjustments: [],
  history: [],
  version: 1,
};

const must = <T>(r: { ok: true; value: T } | { ok: false; error: unknown }): T => {
  if (!r.ok) throw new Error(JSON.stringify(r.error));
  return r.value;
};

describe('timesheet lifecycle', () => {
  it('runs draft → submitted → approved → locked with audit history', () => {
    const submitted = must(transitionTimesheet(sheet, 'submit', alice));
    const approved = must(transitionTimesheet(submitted, 'approve', bob));
    const locked = must(transitionTimesheet(approved, 'lock', payroll));
    expect(locked.status).toBe('locked');
    expect(locked.version).toBe(4);
    expect(locked.history.map((h) => `${h.from}>${h.to}`)).toEqual([
      'draft>submitted',
      'submitted>approved',
      'approved>locked',
    ]);
    expect(sheet.status).toBe('draft'); // input never mutated
  });

  it('rejects invalid transitions and unauthorized actors', () => {
    expect(transitionTimesheet(sheet, 'approve', bob)).toMatchObject({ ok: false, error: { code: 'invalid_transition' } });
    const submitted = must(transitionTimesheet(sheet, 'submit', alice));
    expect(transitionTimesheet(submitted, 'approve', alice)).toMatchObject({ ok: false, error: { code: 'forbidden' } });
    expect(transitionTimesheet(sheet, 'submit', bob)).toMatchObject({ ok: false, error: { code: 'forbidden' } });
  });

  it('requires a reason to return and lets the owner resubmit', () => {
    const submitted = must(transitionTimesheet(sheet, 'submit', alice));
    expect(transitionTimesheet(submitted, 'return', bob, { reason: '   ' })).toMatchObject({
      ok: false,
      error: { code: 'reason_required' },
    });
    const returned = must(transitionTimesheet(submitted, 'return', bob, { reason: 'Missing Friday' }));
    expect(returned.history.at(-1)?.reason).toBe('Missing Friday');
    expect(must(transitionTimesheet(returned, 'submit', alice)).status).toBe('submitted');
  });

  it('lists only actions the actor may take', () => {
    const submitted = must(transitionTimesheet(sheet, 'submit', alice));
    expect(availableTimesheetActions(sheet, alice)).toEqual(['submit']);
    expect(availableTimesheetActions(submitted, alice)).toEqual([]);
    expect(availableTimesheetActions(submitted, bob)).toEqual(['return', 'approve']);
  });
});

describe('post-lock adjustments', () => {
  const locked: Timesheet = { ...sheet, status: 'locked' };

  it('appends adjustments without editing entries', () => {
    const adjusted = must(
      adjustLockedTimesheet(locked, { date: '2026-11-17', deltaMinutes: 30, reason: 'Missed punch' }, payroll),
    );
    expect(adjusted.entries).toBe(locked.entries);
    expect(timesheetTotalMinutes(adjusted)).toBe(480 + 450 + 30);
  });

  it('validates adjustments', () => {
    const adj = { date: '2026-11-17' as const, deltaMinutes: 30, reason: 'x' };
    expect(adjustLockedTimesheet(sheet, adj, payroll)).toMatchObject({ ok: false, error: { code: 'not_locked' } });
    expect(adjustLockedTimesheet(locked, adj, bob)).toMatchObject({ ok: false, error: { code: 'forbidden' } });
    expect(adjustLockedTimesheet(locked, { ...adj, reason: ' ' }, payroll)).toMatchObject({
      ok: false,
      error: { code: 'reason_required' },
    });
    expect(adjustLockedTimesheet(locked, { ...adj, deltaMinutes: 0.5 }, payroll)).toMatchObject({
      ok: false,
      error: { code: 'invalid_adjustment' },
    });
    expect(adjustLockedTimesheet(locked, { ...adj, date: '2026-12-01' }, payroll)).toMatchObject({
      ok: false,
      error: { code: 'invalid_adjustment' },
    });
  });
});
