import type { OrganizationId, UserId } from '../ids';
import { err, ok, type DomainError, type Result } from '../result';
import { localDateKey, type DateKey } from '../time/time';

/**
 * Attendance domain.
 *
 * Raw events are the immutable source of truth. Sessions, totals and
 * exceptions are *derived* by replaying events, so a retry, an offline sync or
 * a correction never mutates history — it only appends.
 */

export const ATTENDANCE_EVENT_TYPES = ['clock_in', 'break_start', 'break_end', 'clock_out'] as const;
export type AttendanceEventType = (typeof ATTENDANCE_EVENT_TYPES)[number];

export type AttendanceStatus = 'off' | 'working' | 'on_break';

export type AttendanceSource = 'mobile' | 'web' | 'kiosk' | 'correction';

export interface AttendanceEvent {
  readonly id: string;
  /** Client-generated key; the same key always maps to the same event. */
  readonly idempotencyKey: string;
  readonly organizationId: OrganizationId;
  readonly userId: UserId;
  readonly type: AttendanceEventType;
  /** Server-authoritative instant (ISO-8601, UTC). */
  readonly occurredAt: string;
  readonly source: AttendanceSource;
  readonly note?: string;
}

const TRANSITIONS: Readonly<Record<AttendanceStatus, Partial<Record<AttendanceEventType, AttendanceStatus>>>> = {
  off: { clock_in: 'working' },
  working: { break_start: 'on_break', clock_out: 'off' },
  on_break: { break_end: 'working', clock_out: 'off' },
};

export type AttendanceErrorCode = 'invalid_transition' | 'out_of_order' | 'scope_mismatch';
export type AttendanceError = DomainError<AttendanceErrorCode>;

export function nextStatus(status: AttendanceStatus, type: AttendanceEventType): Result<AttendanceStatus, AttendanceError> {
  const next = TRANSITIONS[status][type];
  return next === undefined
    ? err({ code: 'invalid_transition', message: `Cannot ${type.replace('_', ' ')} while ${status.replace('_', ' ')}.` })
    : ok(next);
}

/** Actions the user can take from the current status, in display order. */
export const allowedActions = (status: AttendanceStatus): AttendanceEventType[] =>
  ATTENDANCE_EVENT_TYPES.filter((t) => TRANSITIONS[status][t] !== undefined);

const byTime = (a: AttendanceEvent, b: AttendanceEvent) =>
  Date.parse(a.occurredAt) - Date.parse(b.occurredAt) || a.id.localeCompare(b.id);

/** Drop duplicate deliveries (same idempotency key) and sort chronologically. */
export function dedupeEvents(events: readonly AttendanceEvent[]): AttendanceEvent[] {
  const seen = new Set<string>();
  const out: AttendanceEvent[] = [];
  for (const e of [...events].sort(byTime)) {
    if (seen.has(e.idempotencyKey)) continue;
    seen.add(e.idempotencyKey);
    out.push(e);
  }
  return out;
}

export interface BreakInterval {
  readonly start: string;
  readonly end?: string;
}

export interface WorkSession {
  readonly clockIn: string;
  readonly clockOut?: string;
  readonly breaks: readonly BreakInterval[];
  /** Calendar date the shift is attributed to: the local date of clock-in. */
  readonly workDate: DateKey;
  readonly overnight: boolean;
}

export type AttendanceExceptionKind = 'out_of_sequence' | 'break_not_ended' | 'missed_clock_out';

export interface AttendanceException {
  readonly kind: AttendanceExceptionKind;
  readonly eventId?: string;
  readonly at: string;
}

export interface AttendanceReplay {
  readonly status: AttendanceStatus;
  readonly sessions: readonly WorkSession[];
  readonly exceptions: readonly AttendanceException[];
  readonly lastEventAt?: string;
}

export interface ReplayOptions {
  readonly timeZone: string;
  readonly now: Date;
  /** Open sessions longer than this are flagged as a missed clock-out. */
  readonly maxShiftHours?: number;
}

interface MutableSession {
  clockIn: string;
  clockOut?: string;
  breaks: { start: string; end?: string }[];
}

/** Rebuild status, sessions and exceptions from the raw event log. */
export function replayAttendance(events: readonly AttendanceEvent[], options: ReplayOptions): AttendanceReplay {
  const { timeZone, now, maxShiftHours = 16 } = options;
  const exceptions: AttendanceException[] = [];
  const raw: MutableSession[] = [];
  let status: AttendanceStatus = 'off';
  let current: MutableSession | undefined;
  let lastEventAt: string | undefined;

  for (const e of dedupeEvents(events)) {
    const next = nextStatus(status, e.type);
    if (!next.ok) {
      exceptions.push({ kind: 'out_of_sequence', eventId: e.id, at: e.occurredAt });
      continue;
    }
    lastEventAt = e.occurredAt;
    switch (e.type) {
      case 'clock_in':
        current = { clockIn: e.occurredAt, breaks: [] };
        raw.push(current);
        break;
      case 'break_start':
        current?.breaks.push({ start: e.occurredAt });
        break;
      case 'break_end': {
        const open = current?.breaks.at(-1);
        if (open !== undefined) open.end = e.occurredAt;
        break;
      }
      case 'clock_out': {
        const open = current?.breaks.at(-1);
        if (open !== undefined && open.end === undefined) {
          open.end = e.occurredAt;
          exceptions.push({ kind: 'break_not_ended', eventId: e.id, at: e.occurredAt });
        }
        if (current !== undefined) current.clockOut = e.occurredAt;
        current = undefined;
        break;
      }
    }
    status = next.value;
  }

  if (current !== undefined && now.getTime() - Date.parse(current.clockIn) > maxShiftHours * 3_600_000) {
    exceptions.push({ kind: 'missed_clock_out', at: current.clockIn });
  }

  const sessions: WorkSession[] = raw.map((s) => {
    const workDate = localDateKey(new Date(s.clockIn), timeZone);
    const endDate = localDateKey(s.clockOut !== undefined ? new Date(s.clockOut) : now, timeZone);
    const base = { clockIn: s.clockIn, breaks: s.breaks.map((b) => ({ ...b })), workDate, overnight: endDate !== workDate };
    return s.clockOut === undefined ? base : { ...base, clockOut: s.clockOut };
  });

  return lastEventAt === undefined ? { status, sessions, exceptions } : { status, sessions, exceptions, lastEventAt };
}

const span = (start: string, end: string | undefined, now: Date) =>
  Math.max(0, (end !== undefined ? Date.parse(end) : now.getTime()) - Date.parse(start));

export interface SessionTotals {
  readonly elapsedMs: number;
  readonly breakMs: number;
  readonly workedMs: number;
}

/** Totals for a (possibly still open) session; open intervals run until `now`. */
export function sessionTotals(session: WorkSession, now: Date): SessionTotals {
  const elapsedMs = span(session.clockIn, session.clockOut, now);
  const breakMs = session.breaks.reduce((sum, b) => sum + span(b.start, b.end ?? session.clockOut, now), 0);
  return { elapsedMs, breakMs, workedMs: Math.max(0, elapsedMs - breakMs) };
}

export interface RecordOutcome {
  readonly event: AttendanceEvent;
  /** True when this delivery was a retry of an already-recorded event. */
  readonly duplicate: boolean;
}

/**
 * Validate a candidate event against the existing log. Idempotent: replaying a
 * delivery with a known idempotency key returns the original event unchanged.
 */
export function recordEvent(
  log: readonly AttendanceEvent[],
  candidate: AttendanceEvent,
  options: ReplayOptions,
): Result<RecordOutcome, AttendanceError> {
  const existing = log.find((e) => e.idempotencyKey === candidate.idempotencyKey);
  if (existing !== undefined) return ok({ event: existing, duplicate: true });

  if (log.some((e) => e.userId !== candidate.userId || e.organizationId !== candidate.organizationId)) {
    return err({ code: 'scope_mismatch', message: 'Event log must belong to one person in one organization.' });
  }

  const state = replayAttendance(log, options);
  if (state.lastEventAt !== undefined && Date.parse(candidate.occurredAt) < Date.parse(state.lastEventAt)) {
    return err({ code: 'out_of_order', message: 'Event is earlier than the latest recorded event; use a correction.' });
  }
  const next = nextStatus(state.status, candidate.type);
  return next.ok ? ok({ event: candidate, duplicate: false }) : next;
}
