import { describe, expect, it } from 'vitest';
import {
  DepartmentId,
  OrganizationId,
  ROLE_TEMPLATES,
  UserId,
  authorize,
  buildApprovalChain,
  cancelApproval,
  canManageMember,
  currentApprovers,
  decideApproval,
  managerChain,
  rerouteApproval,
  type OrgMember,
  type Permission,
  type ResourceContext,
  type RoleTemplate,
  type Subject,
} from '../src';

/**
 * Hierarchy and organization access, checked exhaustively over a realistic
 * organization rather than case by case.
 *
 *   owner ← vp ← mgr ← sup  ← staff, staff2
 *                  mgr ← sup2 ← staff3
 *   owner ← hr, payroll, it, ops
 */
const ORG = OrganizationId('org_nw');
const OPS = DepartmentId('dept_ops');
const PEOPLE = DepartmentId('dept_people');
const now = new Date('2026-11-23T08:00:00Z');

interface Person {
  readonly id: UserId;
  readonly role: RoleTemplate;
  readonly managerId?: UserId;
  readonly departmentId: DepartmentId;
}
const P = (id: string, role: RoleTemplate, managerId: string | undefined, departmentId = OPS): Person => ({
  id: UserId(id),
  role,
  departmentId,
  ...(managerId !== undefined ? { managerId: UserId(managerId) } : {}),
});
const BASE: Person[] = [
  P('owner', 'owner', undefined),
  P('vp', 'executive', 'owner'),
  P('mgr', 'manager', 'vp'),
  P('sup', 'supervisor', 'mgr'),
  P('staff', 'staff', 'sup'),
  P('staff2', 'staff', 'sup'),
  P('sup2', 'supervisor', 'mgr'),
  P('staff3', 'staff', 'sup2'),
  P('hr', 'hr', 'owner', PEOPLE),
  P('payroll', 'payroll', 'owner', PEOPLE),
  P('it', 'org_admin', 'owner', PEOPLE),
  P('ops', 'operations', 'mgr'),
];

const directoryOf = (people: readonly Person[]) =>
  new Map<UserId, OrgMember>(people.map((p) => [p.id, { id: p.id, roles: [p.role], ...(p.managerId !== undefined ? { managerId: p.managerId } : {}) }]));

function org(people: readonly Person[] = BASE) {
  const dir = directoryOf(people);
  const byId = new Map(people.map((p) => [p.id as string, p]));
  const chain = (id: UserId) => {
    const r = managerChain(id, dir);
    if (!r.ok) throw new Error(r.error.code);
    return r.value;
  };
  const subjectOf = (id: string): Subject => {
    const p = byId.get(id);
    if (p === undefined) throw new Error(id);
    return { userId: p.id, organizationId: ORG, status: 'active', roles: [p.role], teamIds: [], departmentId: p.departmentId, managerChain: chain(p.id) };
  };
  const resourceOf = (id: string): ResourceContext => {
    const p = byId.get(id);
    if (p === undefined) throw new Error(id);
    return { organizationId: ORG, subjectUserId: p.id, departmentId: p.departmentId, managerChain: chain(p.id) };
  };
  const can = (actor: string, permission: Permission, target: string) => authorize(subjectOf(actor), permission, resourceOf(target), now).allowed;
  return { dir, people, subjectOf, resourceOf, can, chain };
}

const DECIDE: Readonly<Record<string, Permission>> = {
  leave: 'timeoff.approve',
  overtime: 'timesheet.approve',
  correction: 'attendance.correct',
};

describe('approval authority matches the reporting line (exhaustive)', () => {
  const o = org([...BASE, P('owner2', 'owner', undefined)]);

  it.each(BASE.map((p) => [p.id as string]))('every approver of %s is authorized for every request kind', (requester) => {
    const chain = buildApprovalChain(UserId(requester), o.dir);
    expect(chain.ok).toBe(true);
    if (!chain.ok) return;
    for (const step of chain.value.steps) {
      expect(step.approverId).not.toBe(requester);
      for (const permission of Object.values(DECIDE)) {
        expect({ requester, approver: step.approverId, permission, ok: o.can(step.approverId, permission, requester) }).toMatchObject({ ok: true });
      }
    }
  });

  it('nobody outside the requester\'s line (other than owners) can approve for them', () => {
    for (const requester of BASE) {
      const line = new Set<string>(o.chain(requester.id));
      for (const actor of BASE) {
        if (actor.id === requester.id || actor.role === 'owner' || line.has(actor.id)) continue;
        for (const permission of Object.values(DECIDE)) {
          expect({ actor: actor.id, requester: requester.id, permission, ok: o.can(actor.id, permission, requester.id) }).toMatchObject({ ok: false });
        }
      }
    }
  });

  it('nobody can approve for themselves, not even an owner', () => {
    for (const p of BASE) for (const permission of Object.values(DECIDE)) expect(o.can(p.id, permission, p.id)).toBe(false);
  });

  it('person-level attendance is visible down the line and to org-wide departments, never up the line otherwise', () => {
    const viewers = { sup: ['staff', 'staff2'], sup2: ['staff3'], mgr: ['sup', 'staff', 'staff2', 'sup2', 'staff3', 'ops'] } as const;
    for (const [viewer, visible] of Object.entries(viewers)) {
      for (const target of BASE) {
        if (target.id === viewer) continue;
        expect({ viewer, target: target.id, ok: o.can(viewer, 'attendance.view', target.id) }).toEqual({ viewer, target: target.id, ok: (visible as readonly string[]).includes(target.id) });
      }
    }
    // Executives get aggregates, not person-level attendance.
    expect(BASE.filter((t) => t.id !== 'vp').some((t) => o.can('vp', 'attendance.view', t.id))).toBe(false);
    // HR, payroll, operations and owners see attendance organization-wide, including up their line.
    for (const viewer of ['hr', 'payroll', 'ops', 'owner']) expect(o.can(viewer, 'attendance.view', 'vp')).toBe(true);
  });
});

describe('owner fallback routing', () => {
  it('routes requests from the top of the organization to another owner', () => {
    const o = org([...BASE, P('owner2', 'owner', undefined)]);
    const chain = buildApprovalChain(UserId('owner'), o.dir);
    expect(chain.ok && chain.value.steps).toEqual([{ level: 'manager', approverId: UserId('owner2'), status: 'pending' }]);
  });

  it('routes people without a manager-tier boss to an owner, keeping supervisor review', () => {
    const o = org([P('owner', 'owner', undefined), P('lead', 'supervisor', undefined), P('worker', 'staff', 'lead')]);
    const chain = buildApprovalChain(UserId('worker'), o.dir);
    expect(chain.ok && chain.value.steps.map((s) => `${s.level}:${s.approverId}:${s.status}`)).toEqual(['supervisor:lead:pending', 'manager:owner:waiting']);
  });

  it('explains when a sole owner has nobody to approve their requests', () => {
    const chain = buildApprovalChain(UserId('owner'), org().dir);
    expect(!chain.ok && chain.error.code).toBe('no_approver');
  });
});

describe('re-routing pending requests when the organization changes', () => {
  const steps = (s: { steps: readonly { level: string; approverId: string; status: string }[] }) => s.steps.map((x) => `${x.level}:${x.approverId}:${x.status}`);

  it('moves a pending request when the reviewer leaves, and keeps finished reviews', () => {
    const before = org();
    const start = buildApprovalChain(UserId('staff'), before.dir);
    if (!start.ok) throw new Error('setup');
    const reviewed = decideApproval(start.value, UserId('sup'), 'approve', { now });
    if (!reviewed.ok) throw new Error('setup');

    // sup leaves: staff now reports to mgr.
    const after = org(BASE.filter((p) => p.id !== 'sup').map((p) => (p.managerId === 'sup' ? { ...p, managerId: UserId('mgr') } : p)));
    const unreviewed = rerouteApproval(start.value, after.dir);
    expect(unreviewed.ok && steps(unreviewed.value)).toEqual(['manager:mgr:pending']);
    const kept = rerouteApproval(reviewed.value, after.dir);
    expect(kept.ok && steps(kept.value)).toEqual(['supervisor:sup:approved', 'manager:mgr:pending']);
  });

  it('follows a reporting-line change and a demotion', () => {
    const start = buildApprovalChain(UserId('staff'), org().dir);
    if (!start.ok) throw new Error('setup');
    const moved = org(BASE.map((p) => (p.id === 'staff' ? { ...p, managerId: UserId('sup2') } : p)));
    const r1 = rerouteApproval(start.value, moved.dir);
    expect(r1.ok && steps(r1.value)).toEqual(['supervisor:sup2:pending', 'manager:mgr:waiting']);

    const demoted = org(BASE.map((p) => (p.id === 'mgr' ? { ...p, role: 'staff' as const } : p)));
    const r2 = rerouteApproval(start.value, demoted.dir);
    expect(r2.ok && steps(r2.value)).toEqual(['supervisor:sup:pending', 'manager:vp:waiting']);
  });

  it('leaves unaffected and closed requests untouched', () => {
    const start = buildApprovalChain(UserId('staff'), org().dir);
    if (!start.ok) throw new Error('setup');
    const same = rerouteApproval(start.value, org().dir);
    expect(same.ok && same.value).toBe(start.value);
    const done = decideApproval(start.value, UserId('mgr'), 'approve', { now });
    if (!done.ok) throw new Error('setup');
    const after = rerouteApproval(done.value, org(BASE.filter((p) => p.id !== 'sup')).dir);
    expect(after.ok && after.value).toBe(done.value);
  });

  it('cancels a departed requester\'s pending request and nobody can decide it', () => {
    const start = buildApprovalChain(UserId('staff'), org().dir);
    if (!start.ok) throw new Error('setup');
    const cancelled = cancelApproval(start.value);
    expect(cancelled.status).toBe('cancelled');
    expect(currentApprovers(cancelled)).toEqual([]);
    expect(steps(cancelled)).toEqual(['supervisor:sup:skipped', 'manager:mgr:skipped']);
    const d = decideApproval(cancelled, UserId('mgr'), 'approve', { now });
    expect(!d.ok && d.error.code).toBe('closed');
    expect(cancelApproval(cancelled)).toBe(cancelled);
  });
});

describe('who may manage whom', () => {
  const o = org([...BASE, P('owner2', 'owner', undefined)]);
  const target = (id: string) => ({ userId: UserId(id), roles: [o.people.find((p) => p.id === id)?.role ?? 'staff'] as RoleTemplate[], resource: o.resourceOf(id) });
  const check = (actor: string, id: string, action: 'edit' | 'change_role' | 'offboard', newRole?: RoleTemplate) =>
    canManageMember(o.subjectOf(actor), target(id), action, { now, ...(newRole !== undefined ? { newRole } : {}) });

  it('owners manage everyone, including other owners, but not themselves', () => {
    for (const p of o.people) {
      if (p.id === 'owner') continue;
      expect(check('owner', p.id, 'edit').allowed).toBe(true);
      expect(check('owner', p.id, 'offboard').allowed).toBe(true);
      for (const role of ROLE_TEMPLATES) expect(check('owner', p.id, 'change_role', role).allowed).toBe(true);
    }
    for (const action of ['edit', 'change_role', 'offboard'] as const) expect(check('owner', 'owner', action, 'staff')).toEqual({ allowed: false, reason: 'self_management' });
  });

  it('HR manages employees but cannot touch owners or demote people with more access', () => {
    expect(check('hr', 'staff', 'edit').allowed).toBe(true);
    expect(check('hr', 'vp', 'edit').allowed).toBe(true); // HR may update an executive's record and reporting line
    expect(check('hr', 'vp', 'offboard').allowed).toBe(true);
    expect(check('hr', 'staff', 'change_role', 'hr').allowed).toBe(true);
    expect(check('hr', 'staff', 'change_role', 'manager')).toEqual({ allowed: false, reason: 'escalation' });
    expect(check('hr', 'vp', 'change_role', 'staff')).toEqual({ allowed: false, reason: 'escalation' });
    expect(check('hr', 'mgr', 'change_role', 'staff')).toEqual({ allowed: false, reason: 'escalation' });
    for (const action of ['edit', 'change_role', 'offboard'] as const) expect(check('hr', 'owner', action, 'staff')).toEqual({ allowed: false, reason: 'protected_member' });
  });

  it('IT admins change roles only within their own access and never edit or offboard', () => {
    expect(check('it', 'staff', 'change_role', 'org_admin').allowed).toBe(true);
    expect(check('it', 'sup', 'change_role', 'staff')).toEqual({ allowed: false, reason: 'escalation' });
    expect(check('it', 'staff', 'edit')).toEqual({ allowed: false, reason: 'missing_permission' });
    expect(check('it', 'staff', 'offboard')).toEqual({ allowed: false, reason: 'missing_permission' });
  });

  it('managers, executives, payroll and staff cannot manage people', () => {
    for (const actor of ['mgr', 'vp', 'payroll', 'staff', 'sup', 'ops']) {
      for (const action of ['edit', 'change_role', 'offboard'] as const) expect(check(actor, 'staff3', action, 'staff').allowed).toBe(false);
    }
  });

  it('refuses inactive actors and other organizations', () => {
    const inactive = { ...o.subjectOf('hr'), status: 'ended' as const };
    expect(canManageMember(inactive, target('staff'), 'edit', { now })).toEqual({ allowed: false, reason: 'inactive_membership' });
    const outsider = { ...o.subjectOf('owner'), userId: UserId('x'), organizationId: OrganizationId('org_other') };
    expect(canManageMember(outsider, target('staff'), 'offboard', { now })).toEqual({ allowed: false, reason: 'tenant_mismatch' });
  });
});
