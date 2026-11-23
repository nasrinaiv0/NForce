import type {
  ApprovalState,
  ApprovalStatus,
  ApproverLevel,
  AttendanceEvent,
  AttendanceEventType,
  AttendanceException,
  AttendanceStatus,
  ClassifiedDay,
  DateKey,
  HolidayKind,
  HomeWidget,
  ModuleId,
  OvertimeAuthorization,
  PayLine,
  PayPolicy,
  RoleTemplate,
  Task,
  TaskPriority,
  TimesheetAction,
  TimesheetStatus,
  TimesheetTransitionRecord,
  UserId,
  WorkSession,
} from '@nforce/core';

/**
 * API contract between the app and the NForce backend.
 *
 * The in-memory implementation and the future Supabase implementation both
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
  readonly teamName?: string;
  readonly manager?: Person;
  readonly modules: readonly ModuleId[];
  readonly widgets: readonly HomeWidget[];
  readonly payPolicy: PayPolicy;
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
  readonly night: boolean;
  readonly holiday?: { readonly kind: HolidayKind; readonly name: string };
  readonly teammates: readonly Person[];
}

export interface LeaveBalance {
  readonly leaveTypeId: string;
  readonly name: string;
  readonly available: number;
  readonly entitled: number;
  readonly hue: number;
}

export type RequestKind = 'leave' | 'day_off' | 'overtime' | 'timesheet' | 'correction';

/** Structured (not pre-formatted) so every locale renders dates and units natively. */
export type RequestPayload =
  | { readonly kind: 'leave'; readonly leaveTypeId: string; readonly leaveType: string; readonly start: DateKey; readonly end: DateKey; readonly days: number; readonly note?: string }
  | { readonly kind: 'day_off'; readonly start: DateKey; readonly end: DateKey; readonly days: number; readonly note?: string }
  | { readonly kind: 'overtime'; readonly date: DateKey; readonly minutes: number; readonly reason: string }
  | { readonly kind: 'timesheet'; readonly periodStart: DateKey; readonly minutes: number; readonly overtimeMinutes: number }
  | { readonly kind: 'correction'; readonly date: DateKey; readonly requestedAt: string; readonly note: string };

export interface ApprovalStepView {
  readonly level: ApproverLevel;
  readonly approver: Person;
  readonly status: ApprovalState['steps'][number]['status'];
  readonly decidedAt?: string;
  readonly reason?: string;
}

export interface ApprovalItem {
  readonly id: string;
  readonly kind: RequestKind;
  readonly payload: RequestPayload;
  readonly requester: Person;
  readonly teamName?: string;
  readonly submittedAt: string;
  readonly status: ApprovalStatus;
  readonly steps: readonly ApprovalStepView[];
  /** The viewer can decide this request right now. */
  readonly canDecide: boolean;
  /** Which step the viewer would decide (manager = final). */
  readonly actingAs?: ApproverLevel;
}

export type MemberStatus = 'working' | 'on_break' | 'missed_punch' | 'late' | 'absent' | 'not_started' | 'done' | 'off';

export interface TeamMember {
  readonly person: Person;
  readonly role: RoleTemplate;
  readonly teamName?: string;
  readonly managerName?: string;
  readonly status: MemberStatus;
  readonly clockIn?: string;
  readonly lateByMinutes?: number;
  readonly todayMinutes: number;
  readonly weekMinutes: number;
  readonly weekOvertimeMinutes: number;
  readonly weekNightMinutes: number;
  readonly pendingRequests: number;
}

export interface TimesheetDay extends ClassifiedDay {
  readonly overtime: OvertimeAuthorization;
  readonly pendingOvertimeMinutes: number;
  readonly breakMinutes: number;
  readonly holidayName?: string;
}

export interface TimesheetView {
  readonly person: Person;
  readonly isMine: boolean;
  readonly periodStart: DateKey;
  readonly periodEnd: DateKey;
  readonly status: TimesheetStatus;
  readonly actions: readonly TimesheetAction[];
  readonly days: readonly TimesheetDay[];
  readonly summary: readonly PayLine[];
  readonly totals: {
    readonly worked: number;
    readonly regular: number;
    readonly overtime: number;
    readonly approvedOvertime: number;
    readonly night: number;
    readonly restDay: number;
    readonly holiday: number;
    readonly weighted: number;
  };
  readonly history: readonly TimesheetTransitionRecord[];
}

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

export interface OvertimeInput {
  readonly date: DateKey;
  readonly minutes: number;
  readonly reason: string;
}

export interface MyRequest {
  readonly id: string;
  readonly kind: RequestKind;
  readonly payload: RequestPayload;
  readonly status: ApprovalStatus;
  readonly submittedAt: string;
  readonly steps: readonly ApprovalStepView[];
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
  myRequests(): Promise<MyRequest[]>;
  previewTimeOff(input: TimeOffInput): Promise<{ days: number; balanceImpact: number; balanceAfter?: number }>;
  requestTimeOff(input: TimeOffInput): Promise<MyRequest>;
  requestOvertime(input: OvertimeInput): Promise<MyRequest>;
  approverPreview(): Promise<readonly ApprovalStepView[]>;
  approvals(): Promise<ApprovalItem[]>;
  decide(id: string, decision: 'approve' | 'return', reason?: string): Promise<void>;
  timesheet(params?: { userId?: UserId; periodStart?: DateKey }): Promise<TimesheetView>;
  timesheetAction(action: TimesheetAction, periodStart: DateKey, reason?: string): Promise<void>;
  team(): Promise<TeamMember[]>;
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
