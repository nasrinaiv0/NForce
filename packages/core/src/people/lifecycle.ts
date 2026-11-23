import type { RoleTemplate } from '../access/permissions';
import type { UserId } from '../ids';
import { err, ok, type DomainError, type Result } from '../result';

/** Employee lifecycle rules shared by every client and mirrored in SQL. */

export interface LifecycleMember {
  readonly id: UserId;
  readonly managerId?: UserId;
  readonly roles: readonly RoleTemplate[];
  readonly active: boolean;
}

export type OffboardErrorCode = 'self_offboarding' | 'last_owner' | 'not_found' | 'already_inactive';

export interface OffboardPlan {
  readonly target: UserId;
  /** Direct reports move to the departing person's manager (never orphaned). */
  readonly reassignments: readonly { readonly userId: UserId; readonly newManagerId?: UserId }[];
}

export function planOffboarding(
  actorId: UserId,
  targetId: UserId,
  members: readonly LifecycleMember[],
): Result<OffboardPlan, DomainError<OffboardErrorCode>> {
  const target = members.find((m) => m.id === targetId);
  if (target === undefined) return err({ code: 'not_found', message: 'That person is not in this organization.' });
  if (!target.active) return err({ code: 'already_inactive', message: 'This person has already been offboarded.' });
  if (actorId === targetId) return err({ code: 'self_offboarding', message: 'You cannot offboard yourself.' });
  const owners = members.filter((m) => m.active && m.roles.includes('owner'));
  if (target.roles.includes('owner') && owners.length <= 1) {
    return err({ code: 'last_owner', message: 'An organization must keep at least one owner.' });
  }
  return ok({
    target: targetId,
    reassignments: members
      .filter((m) => m.active && m.managerId === targetId)
      .map((m) => ({ userId: m.id, ...(target.managerId !== undefined ? { newManagerId: target.managerId } : {}) })),
  });
}
