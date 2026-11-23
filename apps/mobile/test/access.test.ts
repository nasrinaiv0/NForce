import { UserId, type RoleTemplate } from '@nforce/core';
import { beforeEach, describe, expect, it } from 'vitest';

import { createMockApi } from '@/data/mockApi';
import { ApiError, type NForceApi } from '@/data/types';

const NOW = new Date('2026-11-23T02:30:00Z');
let persona: RoleTemplate;
let api: NForceApi;
beforeEach(() => {
  persona = 'owner';
  api = createMockApi({ getPersona: () => persona, now: () => NOW, latencyMs: 0 });
});
const as = (p: RoleTemplate) => {
  persona = p;
};
const rejects = async (p: Promise<unknown>, code: string) => {
  await expect(p).rejects.toBeInstanceOf(ApiError);
  await expect(p).rejects.toMatchObject({ code });
};

describe('organization owner (superior access)', () => {
  it('sees every module and can approve any pending request at any stage', async () => {
    const s = await api.session();
    expect(s.user.name).toBe('Sofia Reyes');
    expect(s.modules).toEqual(expect.arrayContaining(['approvals', 'team', 'people', 'payroll', 'admin', 'crm', 'reports', 'attendance']));
    expect(s.capabilities).toMatchObject({ managePeople: true, offboard: true, approveAnything: true });
    expect(s.capabilities.assignableRoles).toContain('owner');
    const items = await api.approvals();
    const pending = items.filter((a) => a.status === 'pending');
    expect(pending.length).toBeGreaterThan(5);
    expect(pending.every((a) => a.canDecide)).toBe(true);
    const target = pending.find((a) => a.steps.some((x) => x.level === 'supervisor' && x.status === 'pending'));
    await api.decide(target?.id ?? '', 'approve');
    expect((await api.approvals()).find((a) => a.id === target?.id)?.status).toBe('approved');
  });

  it('receives executives’ requests', async () => {
    as('executive');
    const req = await api.requestTimeOff({ kind: 'day_off', start: '2026-12-01', end: '2026-12-01' });
    expect(req.steps.map((x) => x.approver.name)).toEqual(['Sofia Reyes']);
  });

  it('adds, edits and offboards employees with safe reassignment', async () => {
    const hire = await api.createEmployee({ name: 'Mika Lim', title: 'Support Specialist', role: 'staff', managerId: UserId('u_maya'), department: 'Operations', teamName: 'Customer Success' });
    expect(hire.manager?.name).toBe('Maya Santos');
    const promoted = await api.updateEmployee(hire.person.id, { role: 'supervisor', title: 'Team Lead' });
    expect(promoted).toMatchObject({ role: 'supervisor', person: { title: 'Team Lead' } });
    await rejects(api.updateEmployee(UserId('u_elena'), { managerId: UserId('u_jordan') }), 'reporting_cycle');
    await api.offboardEmployee(UserId('u_kenji'));
    const dir = await api.directory();
    expect(dir.find((d) => d.person.id === 'u_kenji')).toBeUndefined();
    expect(dir.find((d) => d.person.id === 'u_lea')?.manager?.name).toBe('Elena Cruz'); // moved up
    await rejects(api.offboardEmployee(UserId('u_sofia')), 'self_offboarding');
  });
});

describe('departments have different access', () => {
  it('HR manages people but cannot approve, grant payroll or open payroll', async () => {
    as('hr');
    const s = await api.session();
    expect(s.capabilities).toMatchObject({ managePeople: true, offboard: true, approveAnything: false });
    expect(s.capabilities.assignableRoles).toEqual(['staff', 'hr']);
    expect(s.modules).not.toContain('payroll');
    expect(s.modules).not.toContain('approvals');
    await rejects(api.payroll(), 'forbidden');
    await rejects(api.createEmployee({ name: 'Pay Person', title: 'Payroll', role: 'payroll', managerId: UserId('u_sofia'), department: 'Finance' }), 'escalation');
    expect((await api.profile(UserId('u_priya'))).sensitive).toBeDefined();
    const ok = await api.createEmployee({ name: 'New Hire', title: 'Specialist', role: 'staff', managerId: UserId('u_kenji'), department: 'Operations' });
    expect(ok.role).toBe('staff');
  });

  it('Payroll prepares payroll but cannot manage people or see confidential HR data', async () => {
    as('payroll');
    const s = await api.session();
    expect(s.capabilities).toMatchObject({ managePeople: false, offboard: false });
    expect((await api.payroll()).rows.length).toBe(17);
    await rejects(api.offboardEmployee(UserId('u_jordan')), 'forbidden');
    expect((await api.profile(UserId('u_jordan'))).sensitive).toBeUndefined();
    expect((await api.attendanceReport({ scope: 'org' })).personLevel).toBe(true); // reads punches
  });

  it('IT admin manages access and audit, not business data', async () => {
    as('org_admin');
    const s = await api.session();
    expect(s.modules).toContain('admin');
    expect(s.modules).not.toContain('payroll');
    expect(s.modules).not.toContain('team');
    expect(s.capabilities.assignableRoles).toEqual(['staff', 'org_admin']);
    await rejects(api.attendanceReport({ scope: 'org' }), 'forbidden');
    expect((await api.admin()).members.length).toBe(17);
  });

  it('Operations manages schedules and sees org attendance, but cannot manage people', async () => {
    as('operations');
    const s = await api.session();
    expect(s.capabilities.managePeople).toBe(false);
    expect((await api.attendanceReport({ scope: 'org' })).personLevel).toBe(true);
    await rejects(api.createEmployee({ name: 'X Y', title: 'Ops', role: 'staff', managerId: UserId('u_elena'), department: 'Operations' }), 'forbidden');
  });
});
