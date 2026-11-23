import { describe, expect, it } from 'vitest';
import {
  ROLE_GRANTS,
  ROLE_TEMPLATES,
  UserId,
  assignableRoles,
  authorize,
  buildApprovalChain,
  canAssignRole,
  decideApproval,
  hasPermission,
  planOffboarding,
  visibleModules,
  type OrgMember,
  type Permission,
  type RoleTemplate,
} from '../src';
import { ALICE, BOB, CARA, ORG, subject } from './fixtures';

const now = new Date('2026-11-23T08:00:00Z');
const has = (role: RoleTemplate, p: Permission) => hasPermission(subject(BOB, [role]), p, now);

describe('departments have distinct access', () => {
  it.each([
    // [role, must have, must NOT have]
    ['hr', ['people.manage', 'people.offboard', 'people.view.sensitive', 'attendance.view'], ['payroll.view', 'timesheet.approve', 'timeoff.approve', 'admin.roles']],
    ['payroll', ['payroll.prepare', 'payroll.export', 'timesheet.lock', 'attendance.view'], ['people.manage', 'people.view.sensitive', 'timesheet.approve', 'admin.roles']],
    ['operations', ['schedule.manage', 'attendance.view', 'work.assign'], ['people.manage', 'payroll.view', 'timeoff.approve']],
    ['org_admin', ['admin.roles', 'admin.settings', 'admin.audit'], ['people.view', 'payroll.view', 'attendance.correct', 'people.manage']],
    ['executive', ['reports.organization', 'timeoff.approve'], ['people.manage', 'payroll.prepare', 'people.view.sensitive']],
  ] as const)('%s', (role, yes, no) => {
    for (const p of yes) expect(has(role, p), `${role} should have ${p}`).toBe(true);
    for (const p of no) expect(has(role, p), `${role} must not have ${p}`).toBe(false);
  });

  it('gives the owner every permission organization-wide', () => {
    const owner = subject(BOB, ['owner'], { teamIds: [] });
    for (const g of ROLE_GRANTS.owner) expect(g.scope).toBe('organization');
    expect(authorize(owner, 'people.offboard', { organizationId: ORG, subjectUserId: CARA }, now).allowed).toBe(true);
    expect(authorize(owner, 'payroll.export', { organizationId: ORG }, now).allowed).toBe(true);
    expect(visibleModules(owner, now)).toEqual(expect.arrayContaining(['approvals', 'team', 'payroll', 'people', 'admin', 'crm', 'reports']));
    // …but still never self-approves.
    expect(authorize(owner, 'timeoff.approve', { organizationId: ORG, subjectUserId: BOB }, now)).toEqual({ allowed: false, reason: 'self_approval' });
  });
});

describe('role assignment never escalates privileges', () => {
  it('lets the owner assign any role and others only roles they fully hold', () => {
    expect(assignableRoles(subject(BOB, ['owner']), now)).toEqual([...ROLE_TEMPLATES]);
    expect(assignableRoles(subject(BOB, ['hr']), now)).toEqual(['staff', 'hr']); // peers, never wider
    expect(assignableRoles(subject(BOB, ['org_admin']), now)).toEqual(['staff', 'org_admin']);
    expect(canAssignRole(subject(BOB, ['hr']), 'payroll', { now })).toEqual({ allowed: false, reason: 'escalation' });
    expect(canAssignRole(subject(BOB, ['staff']), 'staff', { now })).toEqual({ allowed: false, reason: 'missing_permission' });
    expect(canAssignRole(subject(BOB, ['owner']), 'staff', { targetUserId: BOB, now })).toEqual({ allowed: false, reason: 'self_assignment' });
    expect(canAssignRole(subject(BOB, ['owner'], { status: 'suspended' }), 'staff', { now })).toEqual({ allowed: false, reason: 'inactive_membership' });
  });
});

describe('owner approval override', () => {
  const u = UserId;
  const dir = new Map<ReturnType<typeof u>, OrgMember>([
    [u('own'), { id: u('own'), roles: ['owner'] }],
    [u('vp'), { id: u('vp'), managerId: u('own'), roles: ['executive'] }],
    [u('mgr'), { id: u('mgr'), managerId: u('vp'), roles: ['manager'] }],
    [u('sup'), { id: u('sup'), managerId: u('mgr'), roles: ['supervisor'] }],
    [u('st'), { id: u('st'), managerId: u('sup'), roles: ['staff'] }],
  ]);

  it('routes executives to the owner and lets the owner decide anything at any stage', () => {
    const vpReq = buildApprovalChain(u('vp'), dir);
    expect(vpReq.ok && vpReq.value.steps.map((s) => s.approverId)).toEqual(['own']);
    const staff = buildApprovalChain(u('st'), dir);
    if (!staff.ok) throw new Error('chain');
    expect(decideApproval(staff.value, u('own'), 'approve')).toMatchObject({ ok: false, error: { code: 'not_approver' } });
    const r = decideApproval(staff.value, u('own'), 'approve', { override: true });
    expect(r).toMatchObject({ ok: true, value: { status: 'approved' } });
    expect(r.ok && r.value.steps.map((s) => [s.status, s.decidedBy])).toEqual([['skipped', undefined], ['approved', 'own']]);
    const own = buildApprovalChain(u('own'), dir);
    expect(own).toMatchObject({ ok: false, error: { code: 'no_approver' } });
  });

  it('never allows an override to self-approve', () => {
    const vpReq = buildApprovalChain(u('vp'), dir);
    if (!vpReq.ok) throw new Error('chain');
    expect(decideApproval(vpReq.value, u('vp'), 'approve', { override: true })).toMatchObject({ ok: false, error: { code: 'self_approval' } });
  });
});

describe('offboarding', () => {
  const members = [
    { id: ALICE, roles: ['owner'] as RoleTemplate[], active: true },
    { id: BOB, managerId: ALICE, roles: ['manager'] as RoleTemplate[], active: true },
    { id: CARA, managerId: BOB, roles: ['staff'] as RoleTemplate[], active: true },
    { id: UserId('gone'), roles: ['staff'] as RoleTemplate[], active: false },
  ];
  it('reassigns direct reports to the departing manager’s manager', () => {
    expect(planOffboarding(ALICE, BOB, members)).toEqual({ ok: true, value: { target: BOB, reassignments: [{ userId: CARA, newManagerId: ALICE }] } });
  });
  it('blocks self-offboarding, the last owner, unknown and inactive people', () => {
    expect(planOffboarding(BOB, BOB, members)).toMatchObject({ ok: false, error: { code: 'self_offboarding' } });
    expect(planOffboarding(BOB, ALICE, members)).toMatchObject({ ok: false, error: { code: 'last_owner' } });
    expect(planOffboarding(ALICE, UserId('x'), members)).toMatchObject({ ok: false, error: { code: 'not_found' } });
    expect(planOffboarding(ALICE, UserId('gone'), members)).toMatchObject({ ok: false, error: { code: 'already_inactive' } });
  });
});
