import { UserId, type RoleTemplate } from '@nforce/core';
import { beforeEach, describe, expect, it } from 'vitest';

import { createMockApi } from '@/data/mockApi';
import type { NForceApi } from '@/data/types';

/** Employee information on profiles: each block is gated by its own access. */
const NOW = new Date('2026-11-23T02:30:00Z');
let persona: RoleTemplate;
let api: NForceApi;
beforeEach(() => {
  persona = 'staff';
  api = createMockApi({ getPersona: () => persona, now: () => NOW, latencyMs: 0 });
});
const as = (p: RoleTemplate) => {
  persona = p;
};
const JORDAN = UserId('u_jordan');

describe('employee information on profiles', () => {
  it('shows a person all of their own information', async () => {
    const me = await api.profile(JORDAN);
    expect(me.workEmail).toBe('jordan.lee@northwind.ph');
    expect(me.leaveCredits?.map((c) => c.leaveTypeId)).toEqual(['vacation', 'sick', 'wellness']);
    for (const c of me.leaveCredits ?? []) {
      expect(c.used).toBeGreaterThanOrEqual(0);
      expect(c.available + c.used).toBeCloseTo(c.entitled, 5);
    }
    expect(me.attendance?.metrics.scheduledDays).toBeGreaterThan(15);
    expect(me.overtime).toBeDefined();
    expect(me.sensitive).toMatchObject({ employeeId: expect.stringMatching(/^NF-\d{4}$/), emergencyContact: { relationship: expect.any(String) } });
    expect(me.sensitive?.governmentIds.map((g) => g.kind)).toEqual(['sss', 'philhealth', 'pagibig', 'tin']);
    // Government numbers are never sent in full.
    for (const g of me.sensitive?.governmentIds ?? []) expect(g.masked).toContain('•');
  });

  it('counts pending leave days against the right leave type', async () => {
    await api.requestTimeOff({ kind: 'leave', leaveTypeId: 'vacation', start: '2026-12-14', end: '2026-12-15' });
    const vacation = (await api.profile(JORDAN)).leaveCredits?.find((c) => c.leaveTypeId === 'vacation');
    expect(vacation?.pending).toBe(2);
    expect((await api.profile(JORDAN)).leaveHistory?.[0]?.payload).toMatchObject({ kind: 'leave', start: '2026-12-14' });
  });

  it('gives managers credits and attendance for their reports, but not confidential HR details', async () => {
    as('supervisor');
    const p = await api.profile(JORDAN);
    expect(p.leaveCredits).toBeDefined();
    expect(p.attendance).toBeDefined();
    expect(p.sensitive).toBeUndefined();
  });

  it('gives HR confidential details and leave credits organization-wide', async () => {
    as('hr');
    const p = await api.profile(UserId('u_rafael'));
    expect(p.sensitive).toBeDefined();
    expect(p.leaveCredits).toBeDefined();
    expect(p.attendance).toBeDefined();
  });

  it('gives payroll overtime and attendance, but not leave history or HR details', async () => {
    as('payroll');
    const p = await api.profile(JORDAN);
    expect(p.overtime).toBeDefined();
    expect(p.attendance).toBeDefined();
    expect(p.leaveCredits).toBeUndefined();
    expect(p.sensitive).toBeUndefined();
  });

  it('shows colleagues and executives only the directory card', async () => {
    for (const role of ['executive', 'org_admin'] as const) {
      as(role);
      const p = await api.profile(JORDAN);
      expect(p.workEmail).toBeDefined();
      expect({ role, credits: p.leaveCredits, attendance: p.attendance, overtime: p.overtime, sensitive: p.sensitive }).toEqual({
        role,
        credits: undefined,
        attendance: undefined,
        overtime: undefined,
        sensitive: undefined,
      });
    }
    // A supervisor looking up the line sees no more than the directory card either.
    as('supervisor');
    const boss = await api.profile(UserId('u_elena'));
    expect(boss.leaveCredits).toBeUndefined();
    expect(boss.attendance).toBeUndefined();
  });

  it('lists direct reports with their own report counts', async () => {
    as('manager');
    const elena = await api.profile(UserId('u_elena'));
    const maya = elena.directReports.find((r) => r.person.name === 'Maya Santos');
    expect(maya).toMatchObject({ role: 'supervisor', teamName: 'Customer Success' });
    expect(maya?.reports).toBeGreaterThan(2);
  });
});
