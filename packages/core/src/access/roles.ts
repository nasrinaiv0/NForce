import { effectiveGrants, type Subject } from './policy';
import { ROLE_GRANTS, ROLE_TEMPLATES, scopeRank, type RoleTemplate } from './permissions';

/**
 * Role assignment without privilege escalation: an actor may grant a role
 * only if they already hold every permission in it, at least as widely.
 * The organization owner holds everything and can assign any role.
 */
export type AssignDenyReason = 'inactive_membership' | 'missing_permission' | 'escalation' | 'self_assignment';

export function canAssignRole(
  actor: Subject,
  role: RoleTemplate,
  options: { readonly targetUserId?: string; readonly now?: Date } = {},
): { allowed: true } | { allowed: false; reason: AssignDenyReason } {
  if (actor.status !== 'active') return { allowed: false, reason: 'inactive_membership' };
  if (options.targetUserId !== undefined && options.targetUserId === actor.userId) return { allowed: false, reason: 'self_assignment' };
  const { all } = effectiveGrants(actor, options.now ?? new Date());
  if (!all.has('admin.roles') && !all.has('people.manage')) return { allowed: false, reason: 'missing_permission' };
  const covered = ROLE_GRANTS[role].every((g) => {
    const held = all.get(g.permission);
    return held !== undefined && scopeRank(held) >= scopeRank(g.scope);
  });
  return covered ? { allowed: true } : { allowed: false, reason: 'escalation' };
}

export const assignableRoles = (actor: Subject, now: Date = new Date()): RoleTemplate[] =>
  ROLE_TEMPLATES.filter((r) => canAssignRole(actor, r, { now }).allowed);
