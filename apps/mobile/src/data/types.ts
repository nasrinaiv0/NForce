import type {
  AttendanceEvent,
  AttendanceEventType,
  AttendanceException,
  AttendanceStatus,
  DateKey,
  HomeWidget,
  ModuleId,
  RoleTemplate,
  Task,
  TaskPriority,
  Timesheet,
  TimesheetAction,
  UserId,
  WorkSession,
} from '@nforce/core';

/**
 * API contract between the app and the NForce backend.
 *
 * The mock implementation and the future HTTP/Supabase implementation both
 * satisfy this interface, so screens never change when the backend does.
 */

export interface Person {
  readonly id: UserId;
  readonly name: string;
  readonly title: string;
  readonly initials: string;
  readonly hue: number;
}

export interface SessionInfo {
  readonly user: Person;
  readonly organization: { readonly id: string; readonly name: string; readonly timeZone: string };
  readonly role: RoleTemplate;
  readonly modules: readonly ModuleId[];
  readonly widgets: readonly HomeWidget[];
}

export interface AttendanceSnapshot {
  readonly status: AttendanceStatus;
  readonly today?: WorkSession;
  readonly events: readonly AttendanceEvent[];
  readonly exceptions: readonly AttendanceException[];
  readonly weekWorkedMinutes: number;
  readonly scheduledTodayMinutes: number;
}

export interface Shift {
  readonly id: string;
  readonly date: DateKey;
  readonly start: string; // ISO instant
  readonly end: string; // ISO instant
  readonly role: string;
  readonly location: string;
  readonly teammates: readonly Person[];
}

export interface LeaveBalance {
  readonly leaveTypeId: string;
  readonly name: string;
  readonly available: number;
  readonly entitled: number;
  readonly hue: number;
}

export type RequestStatus = 'pending' | 'approved' | 'rejected' | 'cancelled';

export interface TimeOffRequest {
  readonly id: string;
  readonly kind: 'leave' | 'day_off';
  readonly leaveTypeId?: string;
  readonly start: DateKey;
  readonly end: DateKey;
  readonly days: number;
  readonly status: RequestStatus;
  readonly note?: string;
}

/** Structured (not pre-formatted) so every locale renders dates and units natively. */
export type ApprovalPayload =
  | { readonly kind: 'timesheet'; readonly periodStart: DateKey; readonly minutes: number }
  | { readonly kind: 'leave'; readonly leaveType?: string; readonly start: DateKey; readonly end: DateKey; readonly days: number }
  | { readonly kind: 'correction'; readonly date: DateKey; readonly requestedAt: string };

export type ApprovalKind = ApprovalPayload['kind'];

export type ApprovalItem = ApprovalPayload & {
  readonly id: string;
  readonly requester: Person;
  readonly submittedAt: string;
};

export interface TeamPulse {
  readonly onShift: number;
  readonly onBreak: number;
  readonly late: number;
  readonly off: number;
  readonly scheduled: number;
}

export interface NewTaskInput {
  readonly title: string;
  readonly due?: DateKey;
  readonly priority: TaskPriority;
}

export interface TimeOffInput {
  readonly kind: 'leave' | 'day_off';
  readonly leaveTypeId?: string;
  readonly start: DateKey;
  readonly end: DateKey;
  readonly halfDay?: 'am' | 'pm';
  readonly note?: string;
}

export interface NForceApi {
  session(): Promise<SessionInfo>;
  attendance(): Promise<AttendanceSnapshot>;
  clock(type: AttendanceEventType, idempotencyKey: string): Promise<AttendanceSnapshot>;
  shifts(from: DateKey, to: DateKey): Promise<Shift[]>;
  tasks(): Promise<Task[]>;
  createTask(input: NewTaskInput): Promise<Task>;
  setTaskDone(id: string, done: boolean): Promise<Task>;
  balances(): Promise<LeaveBalance[]>;
  timeOffRequests(): Promise<TimeOffRequest[]>;
  previewTimeOff(input: TimeOffInput): Promise<{ days: number; balanceImpact: number; balanceAfter?: number }>;
  requestTimeOff(input: TimeOffInput): Promise<TimeOffRequest>;
  approvals(): Promise<ApprovalItem[]>;
  decide(id: string, decision: 'approve' | 'return', reason?: string): Promise<void>;
  timesheet(): Promise<Timesheet & { readonly actions: readonly TimesheetAction[] }>;
  timesheetAction(action: TimesheetAction, reason?: string): Promise<void>;
  teamPulse(): Promise<TeamPulse>;
}

/** Errors the UI can present. `code` is stable; `message` is user-safe. */
export class ApiError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = 'ApiError';
  }
}
