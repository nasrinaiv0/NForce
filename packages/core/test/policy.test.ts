import { describe, expect, it } from 'vitest';
import {
  PERMISSIONS,
  ROLE_GRANTS,
  ROLE_TEMPLATES,
  authorize,
  hasPermission,
  homeWidgets,
  isPermission,
  mergeGrants,
  requiredScope,
  visibleModules,
} from '../src';
import { ALICE, BOB, CARA, DEPT, ORG, OTHER_ORG, TEAM_A, TEAM_B, subject } from './fixtures';

const now = new Date('2026-11-23T08:00:00Z');
const aliceRecord = { organizationId: ORG, subjectUserId: ALICE, teamId: TEAM_A, departmentId: DEPT };
const caraRecord = { organizationId: ORG, subjectUserId: CARA, teamId: TEAM_B, departmentId: DEPT };

describe('permission catalog', () => {
  it('has no duplicates and every role grant uses a catalog permission', () => {
    expect(new Set(PERMISSIONS).size).toBe(PERMISSIONS.length);
    for (const role of ROLE_TEMPLATES) {
      for (const grant of ROLE_GRANTS[role]) expect(isPermission(grant.permission)).toBe(true);
    }
    expect(isPermission('payroll.delete_everything')).toBe(false);
  });

  it('merges to the widest scope', () => {
    const merged = mergeGrants(
      [{ permission: 'timesheet.view', scope: 'team' }],
      [{ permission: 'timesheet.view', scope: 'self' }],
      [{ permission: 'timesheet.view', scope: 'organization' }],
    );
    expect(merged.get('timesheet.view')).toBe('organization');
  });

  it('never grants sensitive people data or payroll to staff, supervisors, managers or executives', () => {
    for (const role of ['staff', 'supervisor', 'manager', 'executive', 'operations'] as const) {
      const s = subject(ALICE, [role]);
      expect(hasPermission(s, 'people.view.sensitive', now)).toBe(false);
      expect(hasPermission(s, 'payroll.export', now)).toBe(false);
    }
  });
});

describe('authorize', () => {
  it('denies any cross-tenant access, even for administrators', () => {
    const admin = subject(BOB, ['org_admin', 'hr', 'payroll']);
    const d = authorize(admin, 'people.view', { ...aliceRecord, organizationId: OTHER_ORG }, now);
    expect(d).toEqual({ allowed: false, reason: 'tenant_mismatch' });
  });

  it('denies suspended members', () => {
    const s = subject(ALICE, ['staff'], { status: 'suspended' });
    expect(authorize(s, 'attendance.clock', aliceRecord, now)).toEqual({ allowed: false, reason: 'inactive_membership' });
    expect(hasPermission(s, 'attendance.clock', now)).toBe(false);
  });

  it('lets staff act on their own records only', () => {
    const alice = subject(ALICE, ['staff']);
    expect(authorize(alice, 'timesheet.view', aliceRecord, now)).toMatchObject({ allowed: true, scope: 'self' });
    expect(authorize(alice, 'timesheet.view', caraRecord, now)).toEqual({ allowed: false, reason: 'out_of_scope' });
    expect(authorize(alice, 'timesheet.approve', aliceRecord, now)).toEqual({ allowed: false, reason: 'missing_permission' });
  });

  it('scopes supervisors to their team', () => {
    const bob = subject(BOB, ['supervisor']);
    expect(authorize(bob, 'timesheet.approve', aliceRecord, now)).toMatchObject({ allowed: true, via: 'role' });
    expect(authorize(bob, 'timesheet.approve', caraRecord, now)).toEqual({ allowed: false, reason: 'out_of_scope' });
  });

  it('scopes managers to their department', () => {
    const mgr = subject(BOB, ['manager'], { teamIds: [] });
    expect(authorize(mgr, 'timeoff.approve', caraRecord, now).allowed).toBe(true);
    expect(authorize(mgr, 'timeoff.approve', { organizationId: ORG, subjectUserId: CARA }, now)).toEqual({
      allowed: false,
      reason: 'out_of_scope',
    });
  });

  it('enforces separation of duties on approvals', () => {
    const bob = subject(BOB, ['supervisor']);
    const own = { ...aliceRecord, subjectUserId: BOB };
    expect(authorize(bob, 'timesheet.approve', own, now)).toEqual({ allowed: false, reason: 'self_approval' });
  });

  it('protects sensitive records unless explicitly granted', () => {
    const bob = subject(BOB, ['supervisor']);
    expect(authorize(bob, 'people.view', { ...aliceRecord, sensitive: true }, now)).toEqual({
      allowed: false,
      reason: 'sensitive_data',
    });
    const hr = subject(BOB, ['hr']);
    expect(authorize(hr, 'people.view', { ...caraRecord, sensitive: true }, now).allowed).toBe(true);
    // People can always see their own sensitive data.
    const alice = subject(ALICE, ['staff'], { extraGrants: [{ permission: 'people.view', scope: 'self' }] });
    expect(authorize(alice, 'people.view', { ...aliceRecord, sensitive: true }, now).allowed).toBe(true);
  });

  it('blocks ordinary mutations on locked records but allows reads and adjustments', () => {
    const payroll = subject(BOB, ['payroll']);
    const locked = { ...caraRecord, locked: true };
    expect(authorize(payroll, 'timesheet.view', locked, now).allowed).toBe(true);
    expect(authorize(payroll, 'timesheet.adjust', locked, now).allowed).toBe(true);
    const sup = subject(BOB, ['supervisor'], { teamIds: [TEAM_B] });
    expect(authorize(sup, 'timesheet.approve', locked, now)).toEqual({ allowed: false, reason: 'record_locked' });
  });

  it('honours delegations only inside their time window', () => {
    const alice = subject(ALICE, ['staff'], {
      delegations: [
        {
          grants: [{ permission: 'timeoff.approve', scope: 'team' }],
          startsAt: '2026-11-20T00:00:00Z',
          expiresAt: '2026-11-27T00:00:00Z',
          reason: 'Covering for Bob',
        },
      ],
    });
    const teammate = { ...aliceRecord, subjectUserId: CARA };
    expect(authorize(alice, 'timeoff.approve', teammate, now)).toMatchObject({ allowed: true, via: 'delegation' });
    expect(authorize(alice, 'timeoff.approve', teammate, new Date('2026-11-27T00:00:00Z'))).toEqual({
      allowed: false,
      reason: 'missing_permission',
    });
    expect(authorize(alice, 'timeoff.approve', teammate, new Date('2026-11-19T23:59:59Z')).allowed).toBe(false);
  });

  it('computes the narrowest required scope', () => {
    const bob = subject(BOB, ['supervisor']);
    expect(requiredScope(bob, { organizationId: ORG, subjectUserId: BOB })).toBe('self');
    expect(requiredScope(bob, aliceRecord)).toBe('team');
    expect(requiredScope(bob, caraRecord)).toBe('department');
    expect(requiredScope(bob, { organizationId: ORG })).toBe('organization');
  });
});

describe('workspace composition', () => {
  it('gives staff a personal workspace', () => {
    const s = subject(ALICE, ['staff']);
    expect(visibleModules(s, now)).toEqual(['timesheets', 'timeoff', 'people', 'reports']);
    expect(homeWidgets(s, now)).toEqual(['clock', 'next_shift', 'my_work', 'balances']);
  });

  it('adds approvals and team pulse for supervisors', () => {
    const s = subject(BOB, ['supervisor']);
    expect(visibleModules(s, now)).toContain('approvals');
    expect(homeWidgets(s, now).slice(0, 2)).toEqual(['clock', 'approvals']);
    expect(homeWidgets(s, now)).toContain('team_pulse');
  });

  it('shows admin and payroll modules only to those roles', () => {
    expect(visibleModules(subject(BOB, ['org_admin']), now)).toContain('admin');
    expect(visibleModules(subject(BOB, ['payroll']), now)).toContain('payroll');
    expect(visibleModules(subject(BOB, ['executive']), now)).not.toContain('payroll');
    expect(homeWidgets(subject(BOB, ['executive']), now)).toContain('org_metrics');
  });
});
