import type {
  ApprovalState,
  ApprovalStatus,
  ApproverLevel,
  AttendanceEvent,
  AttendanceEventType,
  AttendanceException,
  AttendanceStatus,
  AttendanceMetrics,
  ApprovalSla,
  ClassifiedDay,
  DateKey,
  Deal,
  DealStage,
  PayrollRegister,
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
  /** Server-decided report access (the UI never infers it from job titles). */
  readonly reports: { readonly executive: boolean; readonly organization: boolean };
  /** Server-decided management capabilities. */
  readonly capabilities: {
    readonly managePeople: boolean;
    readonly offboard: boolean;
    readonly assignableRoles: readonly RoleTemplate[];
    readonly approveAnything: boolean;
    /** Can see other people's schedules (team roster). */
    readonly teamSchedule: boolean;
  };
}

export interface EmployeeInput {
  readonly name: string;
  readonly title: string;
  readonly role: RoleTemplate;
  readonly managerId: UserId;
  readonly department: string;
  readonly teamName?: string;
  /** Sign-in email of the person's NForce account (required by the live backend). */
  readonly email?: string;
}

export interface LeaveTypeInfo {
  readonly id: string;
  readonly name: string;
  readonly allowHalfDays: boolean;
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

/** One person-day in a roster. */
export type RosterCell =
  | { readonly kind: 'shift'; readonly start: string; readonly end: string; readonly night: boolean; readonly minutes: number }
  | { readonly kind: 'off' }
  | { readonly kind: 'leave' }
  | { readonly kind: 'holiday'; readonly name: string };

export interface RosterRow {
  readonly person: Person;
  readonly role: RoleTemplate;
  readonly teamName?: string;
  readonly isMe: boolean;
  readonly days: readonly { readonly date: DateKey; readonly cell: RosterCell }[];
  /** Scheduled paid minutes in the range (shift length minus the unpaid break). */
  readonly minutes: number;
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
  /** First clock-in and last clock-out of the day (ISO instants); no out while still working. */
  readonly firstIn?: string;
  readonly lastOut?: string;
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

export type ReportScope = 'me' | 'team' | 'org';

export interface AttendanceFlag {
  readonly date: DateKey;
  readonly kind: 'late' | 'absent' | 'missed_punch';
  readonly person: Person;
  readonly minutes?: number;
}

export interface AttendanceReport {
  readonly scope: ReportScope;
  readonly from: DateKey;
  readonly to: DateKey;
  /** False when the viewer only gets aggregates (e.g. executives). */
  readonly personLevel: boolean;
  readonly metrics: AttendanceMetrics;
  readonly previous: AttendanceMetrics;
  readonly trend: readonly { readonly weekStart: DateKey; readonly metrics: AttendanceMetrics }[];
  readonly daily: readonly { readonly date: DateKey; readonly rate: number; readonly scheduled: number }[];
  readonly groups: readonly { readonly name: string; readonly metrics: AttendanceMetrics }[];
  readonly people: readonly { readonly person: Person; readonly teamName?: string; readonly metrics: AttendanceMetrics }[];
  readonly exceptions: readonly AttendanceFlag[];
  readonly availableScopes: readonly ReportScope[];
}

export interface ExecutiveReport {
  readonly from: DateKey;
  readonly to: DateKey;
  readonly scopeLabel: 'organization' | 'department' | 'team';
  readonly current: AttendanceMetrics;
  readonly previous: AttendanceMetrics;
  readonly trend: readonly { readonly weekStart: DateKey; readonly metrics: AttendanceMetrics }[];
  readonly laborMix: readonly PayLine[];
  readonly weightedMinutes: number;
  readonly teams: readonly { readonly name: string; readonly headcount: number; readonly metrics: AttendanceMetrics }[];
  readonly approvals: ApprovalSla;
  readonly leave: { readonly entitled: number; readonly available: number; readonly takenDays: number };
  readonly payroll: { readonly periodStart: DateKey; readonly ready: boolean; readonly blockers: number; readonly unapprovedOvertimeMinutes: number };
  readonly risks: readonly { readonly key: 'low_attendance' | 'high_overtime' | 'late_trend' | 'approvals_overdue' | 'missed_punches'; readonly subject: string; readonly value: number }[];
}

export interface DirectoryEntry {
  readonly person: Person;
  readonly departmentKey?: string;
  readonly role: RoleTemplate;
  readonly teamName?: string;
  readonly department: string;
  readonly manager?: Person;
}

/** Leave credits for one leave type, in days. */
export interface LeaveCredit extends LeaveBalance {
  /** Days already taken this year. */
  readonly used: number;
  /** Days requested and waiting for approval. */
  readonly pending: number;
}

export interface DirectReport {
  readonly person: Person;
  readonly role: RoleTemplate;
  readonly teamName?: string;
  /** How many people report to this person in turn. */
  readonly reports: number;
}

export type GovernmentIdKind = 'sss' | 'philhealth' | 'pagibig' | 'tin';

export interface PersonProfile extends DirectoryEntry {
  readonly chain: readonly Person[];
  readonly directReports: readonly DirectReport[];
  readonly location: string;
  readonly shift: string;
  readonly restDays: readonly number[];
  /** Work email (visible to everyone in the directory). */
  readonly workEmail: string;
  /** Leave credits, used and pending: for the person and anyone with time-off access to them. */
  readonly leaveCredits?: readonly LeaveCredit[];
  /** Recent leave and day-off requests (same access as leave credits). */
  readonly leaveHistory?: readonly MyRequest[];
  /** Last 30 days of attendance: for the person and anyone with attendance access to them. */
  readonly attendance?: { readonly from: DateKey; readonly to: DateKey; readonly metrics: AttendanceMetrics };
  /** Overtime this month (timesheet access). */
  readonly overtime?: { readonly workedMinutes: number; readonly approvedMinutes: number; readonly pendingMinutes: number };
  /** What the viewer may do to this person (server-computed; mirrors the RPC checks). */
  readonly access: {
    readonly canEdit: boolean;
    readonly canChangeRole: boolean;
    readonly canOffboard: boolean;
    /** Roles the viewer may give this person (empty when roles can't be changed). */
    readonly assignableRoles: readonly RoleTemplate[];
  };
  /** Present only for the person themselves or people.view.sensitive holders (HR, owners). */
  readonly sensitive?: {
    readonly employeeId: string;
    readonly hireDate: DateKey;
    /** Whole months since the hire date. */
    readonly tenureMonths: number;
    readonly employmentType: 'regular' | 'probationary' | 'project';
    /** Date the person became a regular employee. */
    readonly regularizedOn?: DateKey;
    readonly workArrangement: 'onsite' | 'hybrid' | 'remote';
    readonly payGrade: string;
    readonly birthday: DateKey;
    readonly mobile: string;
    readonly personalEmail: string;
    readonly address: string;
    readonly emergencyContact: { readonly name: string; readonly relationship: string; readonly phone: string };
    /** Government numbers, masked except the last digits. */
    readonly governmentIds: readonly { readonly kind: GovernmentIdKind; readonly masked: string }[];
  };
}

export interface PayrollView extends PayrollRegister {
  readonly periodStart: DateKey;
  readonly periodEnd: DateKey;
  readonly locked: boolean;
  readonly canLock: boolean;
}

export interface AuditEntry {
  readonly id: string;
  readonly at: string;
  readonly actor: Person;
  readonly action: string;
  readonly detail: string;
}

export interface AdminOverview {
  readonly members: readonly DirectoryEntry[];
  readonly audit: readonly AuditEntry[];
  readonly holidays: readonly { readonly date: DateKey; readonly kind: HolidayKind; readonly name: string }[];
  readonly payPolicy: PayPolicy;
}

export type NotificationKind = 'approval_needed' | 'request_decided' | 'timesheet_due' | 'missed_punch' | 'payroll_ready';

export interface NotificationItem {
  readonly id: string;
  readonly kind: NotificationKind;
  readonly at: string;
  readonly read: boolean;
  readonly params: Readonly<Record<string, string>>;
  readonly href?: string;
}

export interface NForceApi {
  session(): Promise<SessionInfo>;
  attendance(): Promise<AttendanceSnapshot>;
  clock(type: AttendanceEventType, idempotencyKey: string): Promise<AttendanceSnapshot>;
  shifts(from: DateKey, to: DateKey): Promise<Shift[]>;
  /** Schedules of everyone the viewer may see (themselves first), one cell per day. */
  teamSchedule(from: DateKey, to: DateKey): Promise<RosterRow[]>;
  tasks(): Promise<Task[]>;
  createTask(input: NewTaskInput): Promise<Task>;
  setTaskDone(id: string, done: boolean): Promise<Task>;
  balances(): Promise<LeaveBalance[]>;
  leaveTypes(): Promise<LeaveTypeInfo[]>;
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
  attendanceReport(params: { scope: ReportScope; weeks?: number }): Promise<AttendanceReport>;
  executiveReport(params?: { weeks?: number }): Promise<ExecutiveReport>;
  directory(): Promise<DirectoryEntry[]>;
  createEmployee(input: EmployeeInput): Promise<DirectoryEntry>;
  updateEmployee(id: UserId, patch: Partial<Omit<EmployeeInput, 'name'>>): Promise<DirectoryEntry>;
  offboardEmployee(id: UserId): Promise<void>;
  profile(userId: UserId): Promise<PersonProfile>;
  payroll(periodStart?: DateKey): Promise<PayrollView>;
  lockPayroll(periodStart: DateKey): Promise<void>;
  admin(): Promise<AdminOverview>;
  deals(): Promise<Deal[]>;
  moveDeal(id: string, stage: DealStage, reason?: string): Promise<Deal>;
  notifications(): Promise<NotificationItem[]>;
  markNotificationsRead(ids: readonly string[]): Promise<void>;
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
