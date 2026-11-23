import type { OrganizationId, UserId } from '../ids';
import { err, ok, type DomainError, type Result } from '../result';
import { dateRange, daysBetween, isoWeekday, type DateKey } from '../time/time';

/**
 * Time off.
 *
 * Two deliberately distinct request kinds:
 * - `leave`: an absence under a leave policy. Consumes balance.
 * - `day_off`: a roster preference. NEVER consumes leave balance.
 */

export interface LeavePolicy {
  readonly leaveTypeId: string;
  readonly name: string;
  /** ISO weekdays that are not working days (1 = Monday … 7 = Sunday). */
  readonly nonWorkingWeekdays: readonly number[];
  readonly allowHalfDays: boolean;
  readonly minNoticeDays: number;
  readonly maxConsecutiveDays: number;
  readonly allowNegativeBalance: boolean;
}

interface RequestBase {
  readonly organizationId: OrganizationId;
  readonly userId: UserId;
  readonly start: DateKey;
  readonly end: DateKey;
  readonly note?: string;
}

export interface LeaveRequestDraft extends RequestBase {
  readonly kind: 'leave';
  readonly leaveTypeId: string;
  /** Only meaningful for a single-day request. */
  readonly halfDay?: 'am' | 'pm';
}

export interface DayOffRequestDraft extends RequestBase {
  readonly kind: 'day_off';
}

export type TimeOffDraft = LeaveRequestDraft | DayOffRequestDraft;

export type TimeOffErrorCode =
  | 'invalid_range'
  | 'insufficient_notice'
  | 'too_long'
  | 'no_working_days'
  | 'half_day_not_allowed'
  | 'insufficient_balance'
  | 'overlap'
  | 'policy_mismatch';
export type TimeOffError = DomainError<TimeOffErrorCode>;

export interface TimeOffEvaluation {
  /** Working days covered (0.5 for a half day). */
  readonly days: number;
  /** Balance deducted on approval. Always 0 for day-off requests. */
  readonly balanceImpact: number;
  readonly balanceAfter?: number;
}

export interface ExistingRange {
  readonly start: DateKey;
  readonly end: DateKey;
}

export function countWorkingDays(start: DateKey, end: DateKey, nonWorkingWeekdays: readonly number[]): number {
  return dateRange(start, end).filter((d) => !nonWorkingWeekdays.includes(isoWeekday(d))).length;
}

const overlaps = (a: ExistingRange, b: ExistingRange) => a.start <= b.end && b.start <= a.end;

export interface EvaluateContext {
  readonly today: DateKey;
  readonly existing: readonly ExistingRange[];
  /** Required for `leave` requests. */
  readonly policy?: LeavePolicy;
  readonly availableBalance?: number;
}

/** Validate a draft against policy, balance and overlaps without side effects. */
export function evaluateTimeOff(draft: TimeOffDraft, ctx: EvaluateContext): Result<TimeOffEvaluation, TimeOffError> {
  if (draft.end < draft.start) return err({ code: 'invalid_range', message: 'End date is before start date.' });
  if (draft.start < ctx.today) return err({ code: 'invalid_range', message: 'Requests cannot start in the past.' });
  if (ctx.existing.some((r) => overlaps(r, draft))) {
    return err({ code: 'overlap', message: 'You already have time off requested for some of these dates.' });
  }

  if (draft.kind === 'day_off') {
    return ok({ days: daysBetween(draft.start, draft.end) + 1, balanceImpact: 0 });
  }

  const { policy } = ctx;
  if (policy === undefined || policy.leaveTypeId !== draft.leaveTypeId) {
    return err({ code: 'policy_mismatch', message: 'No policy found for this leave type.' });
  }
  if (daysBetween(ctx.today, draft.start) < policy.minNoticeDays) {
    return err({ code: 'insufficient_notice', message: `${policy.name} needs ${policy.minNoticeDays} days notice.` });
  }
  if (daysBetween(draft.start, draft.end) + 1 > policy.maxConsecutiveDays) {
    return err({ code: 'too_long', message: `${policy.name} allows at most ${policy.maxConsecutiveDays} consecutive days.` });
  }
  if (draft.halfDay !== undefined && (!policy.allowHalfDays || draft.start !== draft.end)) {
    return err({ code: 'half_day_not_allowed', message: 'Half days are only allowed for single-day requests where policy permits.' });
  }

  const working = countWorkingDays(draft.start, draft.end, policy.nonWorkingWeekdays);
  if (working === 0) return err({ code: 'no_working_days', message: 'The selected dates contain no working days.' });
  const days = draft.halfDay !== undefined ? 0.5 : working;

  const available = ctx.availableBalance ?? 0;
  const after = available - days;
  if (after < 0 && !policy.allowNegativeBalance) {
    return err({ code: 'insufficient_balance', message: `Needs ${days} day(s); ${available} available.` });
  }
  return ok({ days, balanceImpact: days, balanceAfter: after });
}
