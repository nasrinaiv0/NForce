import type { DepartmentId, OrganizationId, TeamId, UserId } from '../ids';
import {
  ROLE_GRANTS,
  mergeGrants,
  scopeRank,
  type Grant,
  type Permission,
  type RoleTemplate,
  type Scope,
} from './permissions';

/**
 * RBAC + ABAC policy engine.
 *
 * This module is the single source of truth for "may this person do this to
 * that record". The server MUST call it (or an equivalent SQL policy) on every
 * read and write; clients call it only to shape the UI. Hiding a button is not
 * a security control.
 */

export type MembershipStatus = 'active' | 'invited' | 'suspended' | 'ended';

/** A time-boxed delegation, e.g. a supervisor covering approvals while on leave. */
export interface Delegation {
  readonly grants: readonly Grant[];
  readonly startsAt: string; // ISO-8601 instant
  readonly expiresAt: string; // ISO-8601 instant
  readonly reason: string;
}

/** The authenticated actor, resolved server-side from a verified membership. */
export interface Subject {
  readonly userId: UserId;
  readonly organizationId: OrganizationId;
  readonly status: MembershipStatus;
  readonly roles: readonly RoleTemplate[];
  readonly extraGrants?: readonly Grant[];
  readonly delegations?: readonly Delegation[];
  readonly teamIds: readonly TeamId[];
  readonly departmentId?: DepartmentId;
}

/** Attributes of the record being accessed. */
export interface ResourceContext {
  readonly organizationId: OrganizationId;
  /** The person the record is about (employee, requester, assignee). */
  readonly subjectUserId?: UserId;
  readonly teamId?: TeamId;
  readonly departmentId?: DepartmentId;
  /** Contains salary, medical, identity-document or other confidential fields. */
  readonly sensitive?: boolean;
  /** Workflow state forbids ordinary edits (e.g. a locked timesheet). */
  readonly locked?: boolean;
}

export type DenyReason =
  | 'tenant_mismatch'
  | 'inactive_membership'
  | 'missing_permission'
  | 'out_of_scope'
  | 'sensitive_data'
  | 'record_locked'
  | 'self_approval';

export type Decision =
  | { readonly allowed: true; readonly scope: Scope; readonly via: 'role' | 'delegation' }
  | { readonly allowed: false; readonly reason: DenyReason };

/** Permissions that only read data; everything else is treated as a mutation. */
const READ_ONLY: ReadonlySet<Permission> = new Set<Permission>([
  'attendance.view',
  'schedule.view',
  'timesheet.view',
  'timeoff.view',
  'work.view',
  'people.directory',
  'people.view',
  'people.view.sensitive',
  'payroll.view',
  'crm.view',
  'reports.personal',
  'reports.team',
  'reports.organization',
  'admin.audit',
]);

/** Permissions that may act on a locked record (they are the controlled path). */
const LOCK_EXEMPT: ReadonlySet<Permission> = new Set<Permission>(['timesheet.adjust', 'timesheet.lock']);

/** Approval permissions subject to separation of duties. */
const APPROVALS: ReadonlySet<Permission> = new Set<Permission>([
  'timesheet.approve',
  'timeoff.approve',
  'attendance.correct',
  'payroll.export',
]);

const isActiveDelegation = (d: Delegation, now: Date): boolean => {
  const t = now.getTime();
  return Date.parse(d.startsAt) <= t && t < Date.parse(d.expiresAt);
};

/** Effective permission → scope map, including currently active delegations. */
export function effectiveGrants(subject: Subject, now: Date): {
  readonly fromRoles: Map<Permission, Scope>;
  readonly all: Map<Permission, Scope>;
} {
  const fromRoles = mergeGrants(...subject.roles.map((r) => ROLE_GRANTS[r]), subject.extraGrants ?? []);
  const delegated = (subject.delegations ?? []).filter((d) => isActiveDelegation(d, now)).map((d) => d.grants);
  const all = mergeGrants([...fromRoles].map(([permission, scope]) => ({ permission, scope })), ...delegated);
  return { fromRoles, all };
}

/** The narrowest scope that covers the relationship between actor and record. */
export function requiredScope(subject: Subject, resource: ResourceContext): Scope {
  if (resource.subjectUserId !== undefined && resource.subjectUserId === subject.userId) return 'self';
  if (resource.teamId !== undefined && subject.teamIds.includes(resource.teamId)) return 'team';
  if (resource.departmentId !== undefined && resource.departmentId === subject.departmentId) return 'department';
  return 'organization';
}

/**
 * Decide whether `subject` may exercise `permission` on `resource`.
 * Checks run from cheapest/most fundamental to most specific and fail closed.
 */
export function authorize(
  subject: Subject,
  permission: Permission,
  resource: ResourceContext,
  now: Date = new Date(),
): Decision {
  if (subject.organizationId !== resource.organizationId) return { allowed: false, reason: 'tenant_mismatch' };
  if (subject.status !== 'active') return { allowed: false, reason: 'inactive_membership' };

  const { fromRoles, all } = effectiveGrants(subject, now);
  const granted = all.get(permission);
  if (granted === undefined) return { allowed: false, reason: 'missing_permission' };

  const needed = requiredScope(subject, resource);
  if (scopeRank(granted) < scopeRank(needed)) return { allowed: false, reason: 'out_of_scope' };

  if (resource.sensitive === true && needed !== 'self') {
    const sensitiveScope = all.get('people.view.sensitive');
    if (sensitiveScope === undefined || scopeRank(sensitiveScope) < scopeRank(needed)) {
      return { allowed: false, reason: 'sensitive_data' };
    }
  }

  if (resource.locked === true && !READ_ONLY.has(permission) && !LOCK_EXEMPT.has(permission)) {
    return { allowed: false, reason: 'record_locked' };
  }

  if (APPROVALS.has(permission) && needed === 'self') return { allowed: false, reason: 'self_approval' };

  const roleScope = fromRoles.get(permission);
  const via = roleScope !== undefined && scopeRank(roleScope) >= scopeRank(needed) ? 'role' : 'delegation';
  return { allowed: true, scope: granted, via };
}

/** UI helper: does the subject hold `permission` at any scope right now? */
export function hasPermission(subject: Subject, permission: Permission, now: Date = new Date()): boolean {
  return subject.status === 'active' && effectiveGrants(subject, now).all.has(permission);
}
