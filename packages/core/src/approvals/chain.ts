import type { RoleTemplate } from '../access/permissions';
import type { UserId } from '../ids';
import { err, ok, type DomainError, type Result } from '../result';

/**
 * Hierarchical approval routing.
 *
 * Every request (leave, day off, overtime, timesheet, correction) follows the
 * requester's reporting line:
 *
 *   1. Supervisor review — the nearest supervisor above the requester endorses
 *      or returns it (skipped when the requester has no supervisor below their
 *      manager, e.g. a supervisor's own request).
 *   2. Manager approval — the nearest manager-tier approver gives the FINAL
 *      decision. Managers approve every request in their line and may decide
 *      at any time, which skips any outstanding supervisor review.
 *
 * Nobody can decide their own request. A manager's own request goes to the
 * next manager-tier person above them (e.g. an executive).
 */

export type ApproverLevel = 'supervisor' | 'manager';
export type StepStatus = 'waiting' | 'pending' | 'approved' | 'returned' | 'skipped';
export type ApprovalStatus = 'pending' | 'approved' | 'returned';

export interface OrgMember {
  readonly id: UserId;
  readonly managerId?: UserId;
  readonly roles: readonly RoleTemplate[];
}

export interface ApprovalStep {
  readonly level: ApproverLevel;
  readonly approverId: UserId;
  readonly status: StepStatus;
  readonly decidedBy?: UserId;
  readonly decidedAt?: string;
  readonly reason?: string;
}

export interface ApprovalState {
  readonly requesterId: UserId;
  readonly status: ApprovalStatus;
  readonly steps: readonly ApprovalStep[];
}

export type ApprovalErrorCode =
  | 'unknown_requester'
  | 'reporting_cycle'
  | 'no_approver'
  | 'closed'
  | 'self_approval'
  | 'not_approver'
  | 'reason_required';
export type ApprovalError = DomainError<ApprovalErrorCode>;

const SUPERVISOR_TIER: readonly RoleTemplate[] = ['supervisor'];
const MANAGER_TIER: readonly RoleTemplate[] = ['manager', 'executive'];
const inTier = (m: OrgMember, tier: readonly RoleTemplate[]) => m.roles.some((r) => tier.includes(r));

/** The requester's managers, nearest first. Fails on unknown people or cycles. */
export function managerChain(
  personId: UserId,
  directory: ReadonlyMap<UserId, OrgMember>,
): Result<UserId[], ApprovalError> {
  const self = directory.get(personId);
  if (self === undefined) return err({ code: 'unknown_requester', message: 'Requester is not in the directory.' });
  const chain: UserId[] = [];
  const seen = new Set<UserId>([personId]);
  let next = self.managerId;
  while (next !== undefined) {
    if (seen.has(next)) return err({ code: 'reporting_cycle', message: 'The reporting line contains a cycle.' });
    seen.add(next);
    chain.push(next);
    next = directory.get(next)?.managerId;
  }
  return ok(chain);
}

/** Build the approval steps for a new request. */
export function buildApprovalChain(
  requesterId: UserId,
  directory: ReadonlyMap<UserId, OrgMember>,
): Result<ApprovalState, ApprovalError> {
  const chain = managerChain(requesterId, directory);
  if (!chain.ok) return chain;

  let supervisor: UserId | undefined;
  let manager: UserId | undefined;
  for (const id of chain.value) {
    const m = directory.get(id);
    if (m === undefined) continue;
    if (inTier(m, MANAGER_TIER)) {
      manager = id;
      break;
    }
    if (supervisor === undefined && inTier(m, SUPERVISOR_TIER)) supervisor = id;
  }
  if (manager === undefined) {
    return err({ code: 'no_approver', message: 'No manager-level approver exists in the reporting line.' });
  }

  const steps: ApprovalStep[] = [
    ...(supervisor !== undefined ? [{ level: 'supervisor' as const, approverId: supervisor, status: 'pending' as const }] : []),
    { level: 'manager', approverId: manager, status: supervisor !== undefined ? 'waiting' : 'pending' },
  ];
  return ok({ requesterId, status: 'pending', steps });
}

/** People who may act on the request right now (current step + final manager). */
export function currentApprovers(state: ApprovalState): UserId[] {
  if (state.status !== 'pending') return [];
  const current = state.steps.find((s) => s.status === 'pending');
  const final = state.steps.at(-1);
  return [...new Set([current?.approverId, final?.approverId].filter((x): x is UserId => x !== undefined))];
}

export interface DecideOptions {
  readonly now?: Date;
  readonly reason?: string;
}

/**
 * Apply a decision. The current step's approver decides that step; the final
 * (manager) approver may decide at any time, skipping outstanding steps.
 */
export function decideApproval(
  state: ApprovalState,
  actorId: UserId,
  decision: 'approve' | 'return',
  options: DecideOptions = {},
): Result<ApprovalState, ApprovalError> {
  if (state.status !== 'pending') return err({ code: 'closed', message: 'This request has already been decided.' });
  if (actorId === state.requesterId) return err({ code: 'self_approval', message: 'You cannot decide your own request.' });

  const reason = options.reason?.trim();
  if (decision === 'return' && (reason === undefined || reason.length === 0)) {
    return err({ code: 'reason_required', message: 'Add a reason so the requester knows what to fix.' });
  }

  const currentIndex = state.steps.findIndex((s) => s.status === 'pending');
  const finalIndex = state.steps.length - 1;
  const current = state.steps[currentIndex];
  const final = state.steps[finalIndex];
  if (current === undefined || final === undefined) return err({ code: 'closed', message: 'Nothing left to decide.' });

  let actingIndex: number;
  if (current.approverId === actorId) actingIndex = currentIndex;
  else if (final.approverId === actorId) actingIndex = finalIndex;
  else return err({ code: 'not_approver', message: 'You are not an approver for this request.' });

  const at = (options.now ?? new Date()).toISOString();
  const stamp = { decidedBy: actorId, decidedAt: at, ...(reason !== undefined && reason.length > 0 ? { reason } : {}) };

  const steps = state.steps.map((s, i): ApprovalStep => {
    if (i === actingIndex) return { ...s, status: decision === 'approve' ? 'approved' : 'returned', ...stamp };
    if (i < actingIndex && (s.status === 'pending' || s.status === 'waiting')) return { ...s, status: 'skipped' };
    if (i === actingIndex + 1 && decision === 'approve' && s.status === 'waiting') return { ...s, status: 'pending' };
    return s;
  });

  const status: ApprovalStatus =
    decision === 'return' ? 'returned' : actingIndex === finalIndex ? 'approved' : 'pending';
  return ok({ ...state, status, steps });
}
