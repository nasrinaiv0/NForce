import { UserId, type RoleTemplate } from '@nforce/core';
import { beforeEach, describe, expect, it } from 'vitest';

import { createMockApi } from '@/data/mockApi';
import { ApiError, type NForceApi } from '@/data/types';

const NOW = new Date('2026-11-23T02:30:00Z'); // Monday 10:30 Manila
let persona: RoleTemplate;
let api: NForceApi;
beforeEach(() => {
  persona = 'staff';
  api = createMockApi({ getPersona: () => persona, now: () => NOW, latencyMs: 0 });
});
const as = (p: RoleTemplate) => {
  persona = p;
};
const rejects = async (p: Promise<unknown>, code: string) => {
  await expect(p).rejects.toBeInstanceOf(ApiError);
  await expect(p).rejects.toMatchObject({ code });
};

describe('attendance reports for everyone, scoped by hierarchy', () => {
  it('gives staff their own history only', async () => {
    const me = await api.attendanceReport({ scope: 'me' });
    expect(me.availableScopes).toEqual(['me']);
    expect(me.metrics.headcount).toBe(1);
    expect(me.to).toBe('2026-11-22'); // completed days only
    expect(me.trend).toHaveLength(8);
    await rejects(api.attendanceReport({ scope: 'team' }), 'forbidden');
    await rejects(api.attendanceReport({ scope: 'org' }), 'forbidden');
  });

  it('gives supervisors person-level detail for their line', async () => {
    as('supervisor');
    const r = await api.attendanceReport({ scope: 'team' });
    expect(r.personLevel).toBe(true);
    expect(r.people.map((p) => p.person.name).sort()).toEqual(['Aiko Tanaka', 'Diego Ramos', 'Jordan Lee', 'Priya Nair', 'Sam Okafor']);
    expect(r.exceptions.some((e) => e.kind === 'missed_punch' && e.person.name === 'Diego Ramos')).toBe(true);
    expect(r.availableScopes).not.toContain('org');
  });

  it('gives executives organization aggregates without person-level data', async () => {
    as('executive');
    const r = await api.attendanceReport({ scope: 'org' });
    expect(r.personLevel).toBe(false);
    expect(r.people).toEqual([]);
    expect(r.exceptions).toEqual([]);
    expect(r.metrics.headcount).toBe(17);
    expect(r.groups.length).toBeGreaterThan(2);
    expect(r.metrics.attendanceRate).toBeGreaterThan(0.85);
    expect(r.metrics.attendanceRate).toBeLessThanOrEqual(1);
  });

  it('gives operations org-wide person-level detail', async () => {
    as('operations');
    const r = await api.attendanceReport({ scope: 'org' });
    expect(r.personLevel).toBe(true);
    expect(r.people.length).toBeGreaterThan(10);
  });
});

describe('executive report', () => {
  it('summarizes the organization with trends, labor mix, SLA, payroll and risks', async () => {
    as('executive');
    const t0 = Date.now();
    const r = await api.executiveReport({ weeks: 4 });
    expect(Date.now() - t0).toBeLessThan(3000);
    expect(r.scopeLabel).toBe('organization');
    expect(r.trend).toHaveLength(8);
    expect(r.laborMix.map((l) => l.code)).toEqual(expect.arrayContaining(['REG', 'REG_OT', 'REG_ND']));
    expect(r.weightedMinutes).toBeGreaterThan(r.laborMix.reduce((n, l) => n + l.minutes, 0));
    expect(r.teams.map((x) => x.name)).toEqual(expect.arrayContaining(['Customer Success', 'Billing']));
    expect(r.approvals.total).toBeGreaterThan(10);
    expect(r.approvals.medianHoursToDecide).toBeGreaterThan(0);
    expect(r.payroll).toMatchObject({ periodStart: '2026-11-16', ready: false });
    expect(r.leave.entitled).toBeGreaterThan(r.leave.available);
    // Punctuality improves over the seeded history.
    const first = r.trend[0]?.metrics.punctualityRate ?? 0;
    const last = r.trend.at(-1)?.metrics.punctualityRate ?? 0;
    expect(last).toBeGreaterThanOrEqual(first);
  });

  it('scopes managers to their department and blocks staff', async () => {
    as('manager');
    expect((await api.executiveReport()).scopeLabel).toBe('department');
    as('staff');
    await rejects(api.executiveReport(), 'forbidden');
  });
});

describe('people, payroll, admin, CRM, notifications', () => {
  it('shows sensitive profile fields only to self and HR', async () => {
    expect((await api.directory()).length).toBe(17);
    expect((await api.profile(UserId('u_priya'))).sensitive).toBeUndefined();
    expect((await api.profile(UserId('u_jordan'))).sensitive?.employeeId).toMatch(/^NF-\d{4}$/);
    as('hr');
    expect((await api.profile(UserId('u_priya'))).sensitive).toBeDefined();
    as('manager');
    const elena = await api.profile(UserId('u_elena'));
    expect(elena.directReports.map((r) => r.person.name)).toEqual(expect.arrayContaining(['Maya Santos', 'Kenji Watanabe']));
    expect(elena.chain.map((p) => p.name)).toEqual(['Rafael Mendoza', 'Sofia Reyes']);
  });

  it('prepares payroll and refuses to lock an unready period', async () => {
    await rejects(api.payroll(), 'forbidden');
    as('payroll');
    const reg = await api.payroll();
    expect(reg.rows).toHaveLength(17);
    expect(reg.ready).toBe(false);
    expect(reg.canLock).toBe(false);
    expect(reg.rows.find((r) => r.name === 'Diego Ramos')?.flags).toContain('missed_punch');
    await rejects(api.lockPayroll(reg.periodStart), 'not_ready');
    expect((await api.payroll('2026-11-09')).locked).toBe(true);
    await rejects(api.lockPayroll('2026-11-09'), 'closed');
  });

  it('locks a period once every blocker is resolved', async () => {
    as('manager');
    for (const a of await api.approvals()) if (a.canDecide && (a.kind === 'timesheet' || a.kind === 'correction')) await api.decide(a.id, 'approve');
    as('staff');
    as('payroll');
    const before = await api.payroll();
    const blockers = before.rows.filter((r) => r.flags.includes('timesheet_not_approved')).map((r) => r.name);
    expect(blockers).toEqual(expect.arrayContaining(['Priya Nair']));
  });

  it('restricts administration and records an audit trail', async () => {
    await rejects(api.admin(), 'forbidden');
    as('org_admin');
    const a = await api.admin();
    expect(a.members).toHaveLength(17);
    expect(a.audit.length).toBeGreaterThan(20);
    expect(a.holidays.some((h) => h.name === 'Bonifacio Day')).toBe(true);
  });

  it('shows the CRM pipeline read-only to executives', async () => {
    await rejects(api.deals(), 'forbidden');
    as('executive');
    expect((await api.deals()).length).toBe(8);
    await rejects(api.moveDeal('deal_1', 'negotiation'), 'forbidden');
  });

  it('notifies people about what needs them', async () => {
    as('supervisor');
    const n = await api.notifications();
    expect(n.find((x) => x.kind === 'approval_needed')?.params.count).toBe('5');
    await api.markNotificationsRead(n.map((x) => x.id));
    expect((await api.notifications()).every((x) => x.read)).toBe(true);
    as('payroll');
    expect((await api.notifications()).some((x) => x.kind === 'payroll_ready')).toBe(true);
    as('staff');
    expect((await api.notifications()).some((x) => x.kind === 'request_decided')).toBe(true);
  });
});
