import type { RoleTemplate } from '@nforce/core';
import { beforeEach, describe, expect, it } from 'vitest';

import { createMockApi } from '@/data/mockApi';
import { ApiError, type NForceApi } from '@/data/types';

// Monday 2026-11-23, 10:30 in Manila (UTC+8).
const NOW = new Date('2026-11-23T02:30:00Z');
let persona: RoleTemplate;
let api: NForceApi;

beforeEach(() => {
  persona = 'supervisor';
  api = createMockApi({ getPersona: () => persona, now: () => NOW, latencyMs: 0 });
});

const rejects = async (p: Promise<unknown>, code: string) => {
  await expect(p).rejects.toBeInstanceOf(ApiError);
  await expect(p).rejects.toMatchObject({ code });
};

describe('mock API enforces the same rules as the server', () => {
  it('composes the workspace from the persona', async () => {
    expect((await api.session()).modules).toContain('approvals');
    persona = 'staff';
    const staff = await api.session();
    expect(staff.modules).not.toContain('approvals');
    expect(staff.widgets).not.toContain('team_pulse');
  });

  it('clocks idempotently and validates transitions', async () => {
    const before = await api.attendance();
    expect(before.status).toBe('working'); // seeded clock-in at 08:56
    const first = await api.clock('break_start', 'key-1');
    const retry = await api.clock('break_start', 'key-1');
    expect(first.status).toBe('on_break');
    expect(retry.events).toHaveLength(first.events.length);
    await rejects(api.clock('break_start', 'key-2'), 'invalid_transition');
  });

  it('only shows approvals the actor may decide, and re-checks on decide', async () => {
    expect(await api.approvals()).toHaveLength(5);
    persona = 'hr';
    const hr = await api.approvals();
    expect(hr.every((a) => a.kind === 'leave')).toBe(true);
    persona = 'staff';
    expect(await api.approvals()).toEqual([]);
    await rejects(api.decide('appr_corr', 'approve'), 'forbidden');
  });

  it('requires a reason to return and completes the linked task on decision', async () => {
    await rejects(api.decide('appr_corr', 'return', '  '), 'reason_required');
    await api.decide('appr_corr', 'approve');
    const tasks = await api.tasks();
    expect(tasks.find((t) => t.link?.id === 'appr_corr')?.status).toBe('done');
    await rejects(api.decide('appr_corr', 'approve'), 'not_found');
  });

  it('validates time off with the leave policy and never charges day-off requests', async () => {
    await rejects(api.previewTimeOff({ kind: 'leave', leaveTypeId: 'vacation', start: '2026-11-24', end: '2026-11-24' }), 'insufficient_notice');
    expect(await api.previewTimeOff({ kind: 'leave', leaveTypeId: 'vacation', start: '2026-11-30', end: '2026-12-02' })).toEqual({
      days: 3,
      balanceImpact: 3,
      balanceAfter: 5.5,
    });
    expect((await api.previewTimeOff({ kind: 'day_off', start: '2026-11-25', end: '2026-11-25' })).balanceImpact).toBe(0);
    const req = await api.requestTimeOff({ kind: 'day_off', start: '2026-11-25', end: '2026-11-25', note: '  ' });
    expect(req).not.toHaveProperty('note');
    await rejects(api.requestTimeOff({ kind: 'day_off', start: '2026-11-25', end: '2026-11-25' }), 'overlap');
  });

  it('drives the timesheet state machine with authorization', async () => {
    const sheet = await api.timesheet();
    expect(sheet.status).toBe('draft');
    expect(sheet.actions).toEqual(['submit']);
    await api.timesheetAction('submit');
    expect((await api.timesheet()).status).toBe('submitted');
    await rejects(api.timesheetAction('approve'), 'forbidden'); // no self-approval
  });

  it('rejects empty task titles and hides team pulse from staff', async () => {
    await rejects(api.createTask({ title: '   ', priority: 'normal' }), 'invalid');
    persona = 'staff';
    await rejects(api.teamPulse(), 'forbidden');
  });
});
