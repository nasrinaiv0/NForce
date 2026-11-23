import type { UserId } from '../ids';
import { canAssignRole } from './roles';
import { authorize, type ResourceContext, type Subject } from './policy';
import type { Permission, RoleTemplate } from './permissions';

/**
 * Who may manage whom.
 *
 * Every member action needs the matching permission at a scope that reaches
 * the person (HR and owners hold it organization-wide). On top of that:
 *
 * - Owners are protected: only another owner (holder of `org.manage`) can
 *   edit, re-role or offboard an owner.
 * - Changing a role is only allowed when the actor could assign BOTH the
 *   person's current role and the new one. You can't demote someone with more
 *   access than you, and you can't grant access you don't hold.
 * - Nobody changes their own role or reporting line, or offboards themselves.
 *
 * Editing and offboarding need `people.manage` / `people.offboard` (HR,
 * owners). Role changes accept `people.manage` or `admin.roles` (IT admins).
 */
export type MemberAction = 'edit' | 'change_role' | 'offboard';

export type MemberDenyReason =
  | 'inactive_membership'
  | 'tenant_mismatch'
  | 'missing_permission'
  | 'out_of_scope'
  | 'protected_member'
  | 'escalation'
  | 'self_management';

export interface MemberTarget {
  readonly userId: UserId;
  readonly roles: readonly RoleTemplate[];
  /** Where the person sits (for scope); organizationId must be set. */
  readonly resource: ResourceContext;
}

export function canManageMember(
  actor: Subject,
  target: MemberTarget,
  action: MemberAction,
  options: { readonly newRole?: RoleTemplate; readonly now?: Date } = {},
): { allowed: true } | { allowed: false; reason: MemberDenyReason } {
  const now = options.now ?? new Date();
  if (actor.userId === target.userId) return { allowed: false, reason: 'self_management' };

  // Role changes are open to HR (people.manage) and IT admins (admin.roles).
  const permissions: readonly Permission[] =
    action === 'offboard' ? ['people.offboard'] : action === 'change_role' ? ['people.manage', 'admin.roles'] : ['people.manage'];
  const decisions = permissions.map((p) => authorize(actor, p, target.resource, now));
  if (!decisions.some((d) => d.allowed)) {
    const denied = decisions.map((d) => (d.allowed ? undefined : d.reason));
    const hard = denied.find((r): r is 'tenant_mismatch' | 'inactive_membership' => r === 'tenant_mismatch' || r === 'inactive_membership');
    return { allowed: false, reason: hard ?? (denied.includes('out_of_scope') ? 'out_of_scope' : 'missing_permission') };
  }

  if (target.roles.includes('owner') && !authorize(actor, 'org.manage', { organizationId: target.resource.organizationId }, now).allowed) {
    return { allowed: false, reason: 'protected_member' };
  }

  if (action === 'change_role') {
    const roles = [...target.roles, ...(options.newRole !== undefined ? [options.newRole] : [])];
    for (const role of roles) {
      const assign = canAssignRole(actor, role, { targetUserId: target.userId, now });
      if (!assign.allowed) return { allowed: false, reason: assign.reason === 'self_assignment' ? 'self_management' : assign.reason };
    }
  }
  return { allowed: true };
}
