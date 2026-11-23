import { UserId, type RoleTemplate } from '@nforce/core';
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

const as = (p: RoleTemplate) => {
  persona = p;
};
const rejects = async (p: Promise<unknown>, code: string) => {
  await expect(p).rejects.toBeInstanceOf(ApiError);
  await expect(p).rejects.toMatchObject({ code });
};

describe('workspace by hierarchy', () => {
  it('maps each profile to a person with role-aware modules', async () => {
    const maya = await api.session();
    expect(maya.user.name).toBe('Maya Santos');
    expect(maya.manager?.name).toBe('Elena Cruz');
    expect(maya.modules).toEqual(expect.arrayContaining(['approvals', 'team']));
    as('staff');
    const jordan = await api.session();
    expect(jordan.user.name).toBe('Jordan Lee');
    expect(jordan.modules).not.toContain('team');
    expect(jordan.modules).not.toContain('approvals');
  });

  it('scopes the team view: supervisor → own line, manager → department, executive → none', async () => {
    const names = async () => (await api.team()).map((m) => m.person.name).sort();
    expect(await names()).toEqual(['Aiko Tanaka', 'Diego Ramos', 'Jordan Lee', 'Priya Nair', 'Sam Okafor']);
    as('manager');
    const managerView = await names();
    expect(managerView).toEqual(expect.arrayContaining(['Kenji Watanabe', 'Lea Garcia', 'Maya Santos', 'Jordan Lee', 'Ivy Chen']));
    expect(managerView).not.toContain('Rafael Mendoza');
    as('executive');
    expect(await api.team()).toEqual([]);
    expect((await api.teamPulse()).scheduled).toBeGreaterThan(0); // aggregates only
    as('staff');
    await rejects(api.teamPulse(), 'forbidden');
  });

  it('derives live member status (late, absent, off)', async () => {
    const team = await api.team();
    expect(team.find((m) => m.person.name === 'Sam Okafor')?.lateByMinutes).toBe(24);
    as('manager');
    const all = await api.team();
    expect(all.find((m) => m.person.name === 'Lea Garcia')?.status).toBe('late');
    expect(all.find((m) => m.person.name === 'Nina Petrova')?.status).toBe('off');
    expect(all.find((m) => m.person.name === 'Aiko Tanaka')?.status).toBe('off'); // rest day
    expect(all.find((m) => m.person.name === 'Diego Ramos')).toMatchObject({ status: 'missed_punch', todayMinutes: 0 });
  });
});

describe('timesheets and pay categories', () => {
  it('opens last week when the current week has nothing payable, with OT and rest-day lines', async () => {
    as('staff');
    const ts = await api.timesheet();
    expect(ts.periodStart).toBe('2026-11-16');
    const codes = ts.summary.map((l) => l.code);
    expect(codes).toEqual(expect.arrayContaining(['REG', 'REG_OT', 'RD', 'RD_OT']));
    expect(ts.totals.overtime).toBeGreaterThan(0);
    // Punch jitter of a few minutes is excess time, never overtime.
    expect(ts.days.filter((d) => d.overtimeMinutes > 0 && d.overtimeMinutes < 30)).toEqual([]);
    const tuesday = ts.days.find((d) => d.date === '2026-11-17');
    expect(tuesday?.pendingOvertimeMinutes).toBe(150);
    expect(ts.status).toBe('approved');
  });

  it('classifies the night shift with night differential', async () => {
    const ts = await api.timesheet({ userId: UserId('u_diego'), periodStart: '2026-11-16' });
    expect(ts.totals.night).toBeGreaterThan(0);
    expect(ts.summary.some((l) => l.night)).toBe(true);
  });

  it('enforces timesheet access by hierarchy', async () => {
    await expect(api.timesheet({ userId: UserId('u_jordan') })).resolves.toBeDefined();
    await rejects(api.timesheet({ userId: UserId('u_lea') }), 'forbidden'); // other supervisor's team
    as('staff');
    await rejects(api.timesheet({ userId: UserId('u_priya') }), 'forbidden');
  });
});

describe('hierarchical approvals', () => {
  it("routes a staff request through the supervisor to the manager's final approval", async () => {
    as('staff');
    const req = await api.requestTimeOff({ kind: 'leave', leaveTypeId: 'vacation', start: '2026-12-01', end: '2026-12-02' });
    expect(req.steps.map((s) => [s.level, s.approver.name, s.status])).toEqual([
      ['supervisor', 'Maya Santos', 'pending'],
      ['manager', 'Elena Cruz', 'waiting'],
    ]);
    as('supervisor');
    const mine = (await api.approvals()).find((a) => a.id === req.id);
    expect(mine).toMatchObject({ canDecide: true, actingAs: 'supervisor' });
    await api.decide(req.id, 'approve');
    expect((await api.approvals()).find((a) => a.id === req.id)?.canDecide).toBe(false);
    as('manager');
    expect((await api.approvals()).find((a) => a.id === req.id)).toMatchObject({ canDecide: true, actingAs: 'manager' });
    await api.decide(req.id, 'approve');
    as('staff');
    expect((await api.myRequests()).find((r) => r.id === req.id)?.status).toBe('approved');
    expect((await api.balances()).find((b) => b.leaveTypeId === 'vacation')?.available).toBe(8.5 - 2);
  });

  it('lets managers approve any request in their line at any stage', async () => {
    as('manager');
    const items = await api.approvals();
    const pendingReview = items.filter((a) => a.steps.some((s) => s.level === 'supervisor' && s.status === 'pending'));
    expect(pendingReview.length).toBeGreaterThan(0);
    expect(pendingReview.every((a) => a.canDecide && a.actingAs === 'manager')).toBe(true);
    const target = pendingReview[0];
    await api.decide(target?.id ?? '', 'approve');
    const after = (await api.approvals()).find((a) => a.id === target?.id);
    expect(after?.status).toBe('approved');
    expect(after?.steps.map((s) => s.status)).toEqual(['skipped', 'approved']);
  });

  it('blocks self-approval, outsiders and HR from deciding', async () => {
    as('supervisor');
    const own = (await api.approvals()).length;
    expect(own).toBeGreaterThan(0);
    as('hr');
    const hrView = await api.approvals();
    expect(hrView.length).toBeGreaterThan(0); // HR sees time off org-wide…
    expect(hrView.every((a) => !a.canDecide)).toBe(true); // …but never decides
    await rejects(api.decide(hrView[0]?.id ?? '', 'approve'), 'not_approver');
    as('staff');
    const notMine = hrView.find((a) => a.requester.name !== 'Jordan Lee');
    await rejects(api.decide(notMine?.id ?? '', 'approve'), 'not_approver');
    const mine = (await api.myRequests())[0];
    await rejects(api.decide(mine?.id ?? '', 'approve'), 'self_approval');
  });

  it('requires a reason to return and records it on the requester side', async () => {
    as('supervisor');
    const item = (await api.approvals()).find((a) => a.canDecide && a.kind === 'leave');
    await rejects(api.decide(item?.id ?? '', 'return', ' '), 'reason_required');
    await api.decide(item?.id ?? '', 'return', 'Coverage is thin that week');
    expect((await api.approvals()).find((a) => a.id === item?.id)?.status).toBe('returned');
  });

  it('files overtime and approves it into paid OT', async () => {
    as('staff');
    await rejects(api.requestOvertime({ date: '2026-11-17', minutes: 10, reason: 'x' }), 'invalid');
    await rejects(api.requestOvertime({ date: '2026-11-17', minutes: 60, reason: ' ' }), 'reason_required');
    as('manager');
    const ot = (await api.approvals()).find((a) => a.kind === 'overtime' && a.requester.name === 'Jordan Lee');
    await api.decide(ot?.id ?? '', 'approve');
    as('staff');
    const day = (await api.timesheet({ periodStart: '2026-11-16' })).days.find((d) => d.date === '2026-11-17');
    expect(day?.overtime.unapprovedMinutes).toBe(0);
    expect(day?.overtime.approvedMinutes).toBe(day?.overtimeMinutes);
    expect(day?.overtimeMinutes).toBeGreaterThan(140);
  });

  it('submits a timesheet into the approval chain and approves it', async () => {
    as('staff');
    await api.timesheetAction('submit', '2026-11-23').catch(() => undefined); // empty week is still submittable
    const sheet = await api.timesheet({ periodStart: '2026-11-23' });
    expect(sheet.status).toBe('submitted');
    as('manager');
    const req = (await api.approvals()).find((a) => a.kind === 'timesheet' && a.requester.name === 'Jordan Lee');
    await api.decide(req?.id ?? '', 'approve');
    as('staff');
    expect((await api.timesheet({ periodStart: '2026-11-23' })).status).toBe('approved');
  });

  it('applies approved attendance corrections to the event log', async () => {
    const before = await api.timesheet({ userId: UserId('u_diego'), periodStart: '2026-11-16' });
    as('manager');
    const corr = (await api.approvals()).find((a) => a.kind === 'correction');
    await api.decide(corr?.id ?? '', 'approve');
    as('supervisor');
    const after = await api.timesheet({ userId: UserId('u_diego'), periodStart: '2026-11-16' });
    expect(after.days.length).toBe(before.days.length + 1);
    as('manager');
    expect((await api.team()).find((m) => m.person.name === 'Diego Ramos')?.status).not.toBe('missed_punch');
  });
});

describe('basics still hold', () => {
  it('clocks idempotently and validates transitions', async () => {
    const before = await api.attendance();
    expect(before.status).toBe('working');
    const first = await api.clock('break_start', 'key-0000001');
    const retry = await api.clock('break_start', 'key-0000001');
    expect(first.status).toBe('on_break');
    expect(retry.events).toHaveLength(first.events.length);
    await rejects(api.clock('break_start', 'key-0000002'), 'invalid_transition');
  });

  it('never charges day-off requests to the leave balance', async () => {
    expect((await api.previewTimeOff({ kind: 'day_off', start: '2026-11-25', end: '2026-11-25' })).balanceImpact).toBe(0);
    await rejects(api.previewTimeOff({ kind: 'leave', leaveTypeId: 'vacation', start: '2026-11-24', end: '2026-11-24' }), 'insufficient_notice');
  });

  it('rejects empty task titles', async () => {
    await rejects(api.createTask({ title: '   ', priority: 'normal' }), 'invalid');
  });
});
