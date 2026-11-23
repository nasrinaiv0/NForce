import { authorize, type Subject } from '../access/policy';
import type { Permission } from '../access/permissions';
import type { OrganizationId, TeamId, UserId } from '../ids';
import { err, ok, type DomainError, type Result } from '../result';
import type { DateKey } from '../time/time';

/**
 * Timesheet lifecycle: draft → submitted → approved → locked, with controlled
 * return paths. Locked timesheets are never edited; post-lock changes are
 * appended as auditable adjustments.
 */

export type TimesheetStatus = 'draft' | 'submitted' | 'returned' | 'approved' | 'locked';
export type TimesheetAction = 'submit' | 'return' | 'approve' | 'reopen' | 'lock';

export interface TimesheetEntry {
  readonly date: DateKey;
  readonly workedMinutes: number;
  readonly breakMinutes: number;
}

export interface TimesheetTransitionRecord {
  readonly action: TimesheetAction;
  readonly from: TimesheetStatus;
  readonly to: TimesheetStatus;
  readonly by: UserId;
  readonly at: string;
  readonly reason?: string;
}

export interface TimesheetAdjustment {
  readonly date: DateKey;
  readonly deltaMinutes: number;
  readonly reason: string;
  readonly by: UserId;
  readonly at: string;
}

export interface Timesheet {
  readonly id: string;
  readonly organizationId: OrganizationId;
  readonly userId: UserId;
  readonly teamId?: TeamId;
  readonly periodStart: DateKey;
  readonly periodEnd: DateKey;
  readonly status: TimesheetStatus;
  readonly entries: readonly TimesheetEntry[];
  readonly adjustments: readonly TimesheetAdjustment[];
  readonly history: readonly TimesheetTransitionRecord[];
  /** Optimistic-concurrency version; bump on every write. */
  readonly version: number;
}

interface TransitionRule {
  readonly from: readonly TimesheetStatus[];
  readonly to: TimesheetStatus;
  readonly permission: Permission;
  readonly requiresReason: boolean;
}

export const TIMESHEET_RULES: Readonly<Record<TimesheetAction, TransitionRule>> = {
  submit: { from: ['draft', 'returned'], to: 'submitted', permission: 'timesheet.submit', requiresReason: false },
  return: { from: ['submitted'], to: 'returned', permission: 'timesheet.approve', requiresReason: true },
  approve: { from: ['submitted'], to: 'approved', permission: 'timesheet.approve', requiresReason: false },
  reopen: { from: ['approved'], to: 'returned', permission: 'timesheet.approve', requiresReason: true },
  lock: { from: ['approved'], to: 'locked', permission: 'timesheet.lock', requiresReason: false },
};

export type TimesheetErrorCode = 'invalid_transition' | 'forbidden' | 'reason_required' | 'not_locked' | 'invalid_adjustment';
export type TimesheetError = DomainError<TimesheetErrorCode>;

const resourceOf = (sheet: Timesheet) => ({
  organizationId: sheet.organizationId,
  subjectUserId: sheet.userId,
  ...(sheet.teamId !== undefined ? { teamId: sheet.teamId } : {}),
  locked: sheet.status === 'locked',
});

/** Actions `actor` can take on `sheet` right now (for rendering buttons). */
export function availableTimesheetActions(sheet: Timesheet, actor: Subject, now: Date = new Date()): TimesheetAction[] {
  return (Object.keys(TIMESHEET_RULES) as TimesheetAction[]).filter((action) => {
    const rule = TIMESHEET_RULES[action];
    return rule.from.includes(sheet.status) && authorize(actor, rule.permission, resourceOf(sheet), now).allowed;
  });
}

export function transitionTimesheet(
  sheet: Timesheet,
  action: TimesheetAction,
  actor: Subject,
  options: { readonly now?: Date; readonly reason?: string } = {},
): Result<Timesheet, TimesheetError> {
  const now = options.now ?? new Date();
  const rule = TIMESHEET_RULES[action];
  if (!rule.from.includes(sheet.status)) {
    return err({ code: 'invalid_transition', message: `Cannot ${action} a ${sheet.status} timesheet.` });
  }
  const decision = authorize(actor, rule.permission, resourceOf(sheet), now);
  if (!decision.allowed) return err({ code: 'forbidden', message: `Not allowed: ${decision.reason}.` });

  const reason = options.reason?.trim();
  if (rule.requiresReason && (reason === undefined || reason.length === 0)) {
    return err({ code: 'reason_required', message: `A reason is required to ${action} a timesheet.` });
  }

  const record: TimesheetTransitionRecord = {
    action,
    from: sheet.status,
    to: rule.to,
    by: actor.userId,
    at: now.toISOString(),
    ...(reason !== undefined && reason.length > 0 ? { reason } : {}),
  };
  return ok({ ...sheet, status: rule.to, history: [...sheet.history, record], version: sheet.version + 1 });
}

/** Append a post-lock adjustment. The original entries remain untouched. */
export function adjustLockedTimesheet(
  sheet: Timesheet,
  adjustment: Omit<TimesheetAdjustment, 'by' | 'at'>,
  actor: Subject,
  now: Date = new Date(),
): Result<Timesheet, TimesheetError> {
  if (sheet.status !== 'locked') return err({ code: 'not_locked', message: 'Adjust only locked timesheets; edit others directly.' });
  const decision = authorize(actor, 'timesheet.adjust', resourceOf(sheet), now);
  if (!decision.allowed) return err({ code: 'forbidden', message: `Not allowed: ${decision.reason}.` });
  if (adjustment.reason.trim().length === 0) return err({ code: 'reason_required', message: 'Adjustments require a reason.' });
  if (!Number.isInteger(adjustment.deltaMinutes) || adjustment.deltaMinutes === 0) {
    return err({ code: 'invalid_adjustment', message: 'Adjustment must be a non-zero whole number of minutes.' });
  }
  if (adjustment.date < sheet.periodStart || adjustment.date > sheet.periodEnd) {
    return err({ code: 'invalid_adjustment', message: 'Adjustment date is outside the timesheet period.' });
  }
  const entry: TimesheetAdjustment = { ...adjustment, reason: adjustment.reason.trim(), by: actor.userId, at: now.toISOString() };
  return ok({ ...sheet, adjustments: [...sheet.adjustments, entry], version: sheet.version + 1 });
}

/** Payable minutes = recorded work + all adjustments. */
export const timesheetTotalMinutes = (sheet: Timesheet): number =>
  sheet.entries.reduce((s, e) => s + e.workedMinutes, 0) + sheet.adjustments.reduce((s, a) => s + a.deltaMinutes, 0);
