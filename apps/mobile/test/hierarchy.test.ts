import { ROLE_TEMPLATES, UserId, type RoleTemplate } from '@nforce/core';
import { beforeEach, describe, expect, it } from 'vitest';

import { createMockApi } from '@/data/mockApi';
import { ApiError, type NForceApi } from '@/data/types';

/**
 * Hierarchy and organization access through the real backend endpoints, for
 * every demo persona. These are the same guarantees the SQL RPCs enforce.
 */
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
/** Ids of everyone above `id` in the reporting line. */
const lineOf = async (id: UserId) => new Set((await api.profile(id)).chain.map((p) => p.id as string));

/** Org-wide attendance by design: HR, payroll, operations, owner. */
const ORG_WIDE_ATTENDANCE: readonly RoleTemplate[] = ['hr', 'payroll', 'operations', 'owner'];

describe.each(ROLE_TEMPLATES.map((r) => [r]))('%s', (role) => {
  it('can decide exactly the requests in their reporting line (owners: all), never their own', async () => {
    as(role);
    const me = (await api.session()).user.id;
    for (const item of await api.approvals()) {
      expect(item.requester.id).not.toBe(me);
      if (item.status !== 'pending') {
        expect(item.canDecide).toBe(false);
        continue;
      }
      const inLine = (await lineOf(item.requester.id)).has(me);
      const isApprover = item.steps.some((s) => s.approver.id === me && (s.status === 'pending' || s.status === 'waiting'));
      expect({ id: item.id, canDecide: item.canDecide }).toEqual({ id: item.id, canDecide: role === 'owner' || (inLine && isApprover) });
    }
  });

  it('cannot decide requests the inbox marks as not decidable', async () => {
    as(role);
    const blocked = (await api.approvals()).filter((a) => a.status === 'pending' && !a.canDecide).slice(0, 3);
    for (const item of blocked) await expect(api.decide(item.id, 'approve')).rejects.toBeInstanceOf(ApiError);
  });

  it('sees person-level team status only down their line (or organization-wide by department)', async () => {
    as(role);
    const me = (await api.session()).user.id;
    for (const member of await api.team()) {
      if (ORG_WIDE_ATTENDANCE.includes(role)) continue;
      expect({ member: member.person.id, inLine: (await lineOf(member.person.id)).has(me) }).toEqual({ member: member.person.id, inLine: true });
    }
    if (role === 'executive' || role === 'staff' || role === 'org_admin') expect(await api.team()).toEqual([]);
  });

  it('only gets management actions the backend will accept', async () => {
    as(role);
    const me = (await api.session()).user.id;
    for (const entry of await api.directory()) {
      const access = (await api.profile(entry.person.id)).access;
      if (entry.person.id === me) expect(access).toEqual({ canEdit: false, canChangeRole: false, canOffboard: false, assignableRoles: [] });
      if (!access.canEdit) await rejects(api.updateEmployee(entry.person.id, { title: 'Changed title' }), entry.person.id === me ? 'self_management' : entry.role === 'owner' && ['hr'].includes(role) ? 'protected_member' : 'forbidden');
    }
  });
});

describe('HR cannot overreach', () => {
  it('cannot demote an executive or manage the owner', async () => {
    as('hr');
    await rejects(api.updateEmployee(UserId('u_rafael'), { role: 'staff' }), 'escalation');
    await rejects(api.updateEmployee(UserId('u_elena'), { role: 'staff' }), 'escalation');
    await rejects(api.offboardEmployee(UserId('u_sofia')), 'protected_member');
    await rejects(api.updateEmployee(UserId('u_sofia'), { title: 'Founder' }), 'protected_member');
    expect((await api.profile(UserId('u_sofia'))).access).toEqual({ canEdit: false, canChangeRole: false, canOffboard: false, assignableRoles: [] });
  });

  it('may still update an executive’s record and offboard them, and give staff only roles HR holds', async () => {
    as('hr');
    const vp = (await api.profile(UserId('u_rafael'))).access;
    expect(vp).toMatchObject({ canEdit: true, canChangeRole: false, canOffboard: true });
    expect((await api.profile(UserId('u_jordan'))).access.assignableRoles).toEqual(['staff', 'hr']);
  });

  it('IT admins can re-role staff within IT access but cannot edit records', async () => {
    as('org_admin');
    const jordan = (await api.profile(UserId('u_jordan'))).access;
    expect(jordan).toMatchObject({ canEdit: false, canChangeRole: true, canOffboard: false });
    expect(jordan.assignableRoles).toEqual(['staff', 'org_admin']);
  });
});

describe('pending requests follow organization changes', () => {
  it('re-routes requests waiting on a departed supervisor and cancels the departed person’s own requests', async () => {
    as('staff');
    const mine = await api.requestTimeOff({ kind: 'day_off', start: '2026-12-21', end: '2026-12-21' });
    expect(mine.steps.map((s) => `${s.level}:${s.approver.name}:${s.status}`)).toEqual(['supervisor:Maya Santos:pending', 'manager:Elena Cruz:waiting']);
    as('supervisor');
    const hers = await api.requestTimeOff({ kind: 'day_off', start: '2026-12-22', end: '2026-12-22' });

    as('hr');
    await api.offboardEmployee(UserId('u_maya'));

    as('staff');
    const after = (await api.myRequests()).find((r) => r.id === mine.id);
    expect(after?.steps.map((s) => `${s.level}:${s.approver.name}:${s.status}`)).toEqual(['manager:Elena Cruz:pending']);
    as('manager');
    const inbox = await api.approvals();
    expect(inbox.find((a) => a.id === mine.id)?.canDecide).toBe(true);
    expect(inbox.find((a) => a.id === hers.id)?.status).toBe('cancelled');
    await rejects(api.decide(hers.id, 'approve'), 'closed');
  });

  it('moves requests when a reporting line changes', async () => {
    as('staff');
    const mine = await api.requestTimeOff({ kind: 'day_off', start: '2026-12-23', end: '2026-12-23' });
    as('hr');
    await api.updateEmployee(UserId('u_jordan'), { managerId: UserId('u_kenji') });
    as('staff');
    const after = (await api.myRequests()).find((r) => r.id === mine.id);
    expect(after?.steps.map((s) => `${s.level}:${s.approver.name}`)).toEqual(['supervisor:Kenji Watanabe', 'manager:Elena Cruz']);
    as('supervisor');
    expect((await api.approvals()).find((a) => a.id === mine.id)?.canDecide ?? false).toBe(false);
  });

  it('an offboarded person loses access everywhere', async () => {
    as('hr');
    await api.offboardEmployee(UserId('u_jordan'));
    as('staff');
    await rejects(api.attendance(), 'forbidden');
    await rejects(api.clock('clock_in', 'k-after-offboarding'), 'forbidden');
    await rejects(api.directory(), 'forbidden');
  });

  it('managers cannot be chosen once offboarded', async () => {
    as('hr');
    await api.offboardEmployee(UserId('u_kenji'));
    await rejects(api.updateEmployee(UserId('u_jordan'), { managerId: UserId('u_kenji') }), 'invalid');
  });
});

describe('top of the organization', () => {
  it('tells a sole owner why their own requests cannot be routed', async () => {
    as('owner');
    await rejects(api.approverPreview(), 'no_approver');
  });

  it('routes an owner’s request to a second owner, who still cannot self-approve', async () => {
    as('owner');
    await api.updateEmployee(UserId('u_rafael'), { role: 'owner' });
    const req = await api.requestTimeOff({ kind: 'day_off', start: '2026-12-28', end: '2026-12-28' });
    expect(req.steps.map((s) => `${s.level}:${s.approver.name}`)).toEqual(['manager:Rafael Mendoza']);
    await rejects(api.decide(req.id, 'approve'), 'self_approval');
  });
});
