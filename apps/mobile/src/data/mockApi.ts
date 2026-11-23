import {
  DepartmentId,
  OrganizationId,
  TeamId,
  UserId,
  addDays,
  authorize,
  availableTimesheetActions,
  dateRange,
  evaluateTimeOff,
  homeWidgets,
  instantFromZoned,
  isoWeekday,
  localDateKey,
  recordEvent,
  replayAttendance,
  sessionTotals,
  transitionTimesheet,
  visibleModules,
  type AttendanceEvent,
  type AttendanceEventType,
  type DateKey,
  type LeavePolicy,
  type Permission,
  type ResourceContext,
  type RoleTemplate,
  type Subject,
  type Task,
  type Timesheet,
  type TimesheetAction,
} from '@nforce/core';

import {
  ApiError,
  type ApprovalItem,
  type ApprovalKind,
  type AttendanceSnapshot,
  type LeaveBalance,
  type NForceApi,
  type Person,
  type SessionInfo,
  type Shift,
  type TimeOffInput,
  type TimeOffRequest,
} from './types';

/**
 * In-memory NForce backend used for development, demos, previews and tests.
 *
 * It is intentionally "honest": every write goes through the same
 * @nforce/core rules the real server will enforce (authorization, idempotent
 * attendance, leave policy, timesheet state machine). The UI therefore
 * exercises real business rules today, and swapping to the HTTP client later
 * changes no screen code.
 */

export interface MockApiOptions {
  readonly getPersona: () => RoleTemplate;
  readonly now?: () => Date;
  readonly latencyMs?: number;
}

const ORG = OrganizationId('org_northwind');
const TEAM = TeamId('team_cx');
const DEPT = DepartmentId('dept_ops');
const TZ = 'Asia/Manila';

const person = (id: string, name: string, title: string, hue: number): Person => ({
  id: UserId(id),
  name,
  title,
  hue,
  initials: name
    .split(' ')
    .map((p) => p[0] ?? '')
    .join('')
    .slice(0, 2)
    .toUpperCase(),
});

const TITLES: Readonly<Record<RoleTemplate, string>> = {
  staff: 'Customer Success Specialist',
  supervisor: 'Team Lead, Customer Success',
  manager: 'Operations Manager',
  operations: 'Workforce Planner',
  hr: 'HR Business Partner',
  payroll: 'Payroll Specialist',
  executive: 'VP, Operations',
  org_admin: 'Workspace Administrator',
};

const TEAMMATES: readonly Person[] = [
  person('u_jordan', 'Jordan Lee', 'Customer Success Specialist', 200),
  person('u_priya', 'Priya Nair', 'Senior Specialist', 330),
  person('u_diego', 'Diego Ramos', 'Customer Success Specialist', 25),
  person('u_aiko', 'Aiko Tanaka', 'Quality Analyst', 160),
  person('u_sam', 'Sam Okafor', 'Customer Success Specialist', 270),
];

const POLICIES: readonly LeavePolicy[] = [
  { leaveTypeId: 'vacation', name: 'Vacation', nonWorkingWeekdays: [6, 7], allowHalfDays: true, minNoticeDays: 3, maxConsecutiveDays: 15, allowNegativeBalance: false },
  { leaveTypeId: 'sick', name: 'Sick leave', nonWorkingWeekdays: [6, 7], allowHalfDays: true, minNoticeDays: 0, maxConsecutiveDays: 10, allowNegativeBalance: false },
  { leaveTypeId: 'wellness', name: 'Wellness day', nonWorkingWeekdays: [6, 7], allowHalfDays: false, minNoticeDays: 1, maxConsecutiveDays: 1, allowNegativeBalance: false },
];

const APPROVAL_PERMISSION: Readonly<Record<ApprovalKind, Permission>> = {
  timesheet: 'timesheet.approve',
  leave: 'timeoff.approve',
  correction: 'attendance.correct',
};

const delay = (ms: number) => (ms > 0 ? new Promise<void>((r) => setTimeout(r, ms)) : Promise.resolve());

export function createMockApi(options: MockApiOptions): NForceApi {
  const now = options.now ?? (() => new Date());
  const latency = options.latencyMs ?? 350;
  const me = person('u_maya', 'Maya Santos', TITLES.supervisor, 230);
  let seq = 0;
  const nextId = (prefix: string) => `${prefix}_${(++seq).toString(36)}`;

  const subject = (): Subject => ({
    userId: me.id,
    organizationId: ORG,
    status: 'active',
    roles: [options.getPersona()],
    teamIds: [TEAM],
    departmentId: DEPT,
  });
  const today = (): DateKey => localDateKey(now(), TZ);
  const at = (date: DateKey, h: number, m: number) => instantFromZoned(date, h, m, TZ).toISOString();
  const weekStart = (d: DateKey) => addDays(d, 1 - isoWeekday(d));

  const ensure = (permission: Permission, resource: ResourceContext) => {
    const decision = authorize(subject(), permission, resource, now());
    if (!decision.allowed) throw new ApiError('forbidden', `You don't have access to this (${decision.reason}).`);
  };
  const mine: ResourceContext = { organizationId: ORG, subjectUserId: me.id, teamId: TEAM, departmentId: DEPT };
  const teammate = (p: Person): ResourceContext => ({ organizationId: ORG, subjectUserId: p.id, teamId: TEAM, departmentId: DEPT });

  // ---------------------------------------------------------------- seed data
  const seedToday = today();
  const isShiftDay = (d: DateKey) => isoWeekday(d) <= 5;

  const shiftFor = (date: DateKey): Shift | undefined => {
    if (!isShiftDay(date)) return undefined;
    const wd = isoWeekday(date);
    const crew = TEAMMATES.filter((_, i) => (i + wd) % 2 === 0 || i === wd - 1);
    return {
      id: `shift_${date}`,
      date,
      start: at(date, 9, 0),
      end: at(date, 18, 0),
      role: 'Customer Success · Tier 2',
      location: wd % 2 === 1 ? 'Makati HQ · Floor 12' : 'Remote',
      teammates: crew,
    };
  };

  let events: AttendanceEvent[] = [];
  const seedEvent = (type: AttendanceEventType, occurredAt: string) =>
    events.push({ id: nextId('evt'), idempotencyKey: nextId('seed'), organizationId: ORG, userId: me.id, type, occurredAt, source: 'mobile' });

  for (const d of dateRange(weekStart(seedToday), addDays(seedToday, -1))) {
    if (!isShiftDay(d)) continue;
    seedEvent('clock_in', at(d, 8, 52 + (isoWeekday(d) % 3) * 2));
    seedEvent('break_start', at(d, 12, 30));
    seedEvent('break_end', at(d, 13, 15));
    seedEvent('clock_out', at(d, 18, 2 + isoWeekday(d)));
  }
  if (isShiftDay(seedToday)) {
    const t = now().getTime();
    const clockIn = at(seedToday, 8, 56);
    if (Date.parse(clockIn) < t) {
      seedEvent('clock_in', clockIn);
      const bs = at(seedToday, 12, 30);
      const be = at(seedToday, 13, 15);
      if (Date.parse(bs) < t) seedEvent('break_start', bs);
      if (Date.parse(be) < t) seedEvent('break_end', be);
    }
  }

  let tasks: Task[] = [
    { id: nextId('task'), title: 'Review Q4 coverage plan', status: 'todo', priority: 'high', assigneeId: me.id, createdById: me.id, due: addDays(seedToday, -1) },
    { id: nextId('task'), title: "Approve Diego's attendance correction", status: 'todo', priority: 'urgent', assigneeId: me.id, createdById: me.id, due: seedToday, link: { kind: 'approval', id: 'appr_corr', label: 'Approval' } },
    { id: nextId('task'), title: 'Prepare shift handover notes', status: 'in_progress', priority: 'normal', assigneeId: me.id, createdById: me.id, due: seedToday },
    { id: nextId('task'), title: 'Complete data privacy refresher', status: 'todo', priority: 'normal', assigneeId: me.id, createdById: UserId('u_hr'), due: addDays(seedToday, 3) },
    { id: nextId('task'), title: 'Coaching session with Priya', status: 'todo', priority: 'normal', assigneeId: me.id, createdById: me.id, due: addDays(seedToday, 5) },
    { id: nextId('task'), title: 'Collect holiday availability', status: 'todo', priority: 'low', assigneeId: me.id, createdById: me.id },
    { id: nextId('task'), title: 'Submit November expense report', status: 'done', priority: 'normal', assigneeId: me.id, createdById: me.id, due: addDays(seedToday, -2) },
  ];

  const balances: LeaveBalance[] = [
    { leaveTypeId: 'vacation', name: 'Vacation', available: 8.5, entitled: 15, hue: 225 },
    { leaveTypeId: 'sick', name: 'Sick leave', available: 5, entitled: 7, hue: 150 },
    { leaveTypeId: 'wellness', name: 'Wellness day', available: 2, entitled: 2, hue: 285 },
  ];

  let requests: TimeOffRequest[] = [
    { id: nextId('req'), kind: 'day_off', start: addDays(seedToday, 10), end: addDays(seedToday, 10), days: 1, status: 'pending', note: 'Family event' },
    { id: nextId('req'), kind: 'leave', leaveTypeId: 'vacation', start: addDays(seedToday, 24), end: addDays(seedToday, 26), days: 3, status: 'approved' },
  ];

  const [jordan, priya, diego, aiko, sam] = TEAMMATES as [Person, Person, Person, Person, Person];
  const ago = (minutes: number) => new Date(now().getTime() - minutes * 60_000).toISOString();
  const lastWeek = weekStart(addDays(seedToday, -7));
  let approvals: (ApprovalItem & { resource: ResourceContext })[] = [
    { id: 'appr_corr', kind: 'correction', requester: diego, date: addDays(seedToday, -2), requestedAt: at(addDays(seedToday, -2), 18, 4), submittedAt: ago(42), resource: teammate(diego) },
    { id: nextId('appr'), kind: 'leave', requester: priya, leaveType: 'Vacation', start: addDays(seedToday, 8), end: addDays(seedToday, 10), days: 3, submittedAt: ago(95), resource: teammate(priya) },
    { id: nextId('appr'), kind: 'timesheet', requester: jordan, periodStart: lastWeek, minutes: 41 * 60 + 30, submittedAt: ago(180), resource: teammate(jordan) },
    { id: nextId('appr'), kind: 'leave', requester: aiko, start: addDays(seedToday, 12), end: addDays(seedToday, 12), days: 1, submittedAt: ago(320), resource: teammate(aiko) },
    { id: nextId('appr'), kind: 'timesheet', requester: sam, periodStart: lastWeek, minutes: 38 * 60 + 15, submittedAt: ago(1440), resource: teammate(sam) },
  ];

  let timesheetState: Pick<Timesheet, 'status' | 'history' | 'version'> = { status: 'draft', history: [], version: 1 };

  // ---------------------------------------------------------------- helpers
  const snapshot = (): AttendanceSnapshot => {
    const t = now();
    const replay = replayAttendance(events, { timeZone: TZ, now: t });
    const d = today();
    const open = replay.sessions.find((s) => s.clockOut === undefined);
    const todays = open ?? [...replay.sessions].reverse().find((s) => s.workDate === d);
    const ws = weekStart(d);
    const weekWorkedMinutes = Math.floor(
      replay.sessions.filter((s) => s.workDate >= ws).reduce((sum, s) => sum + sessionTotals(s, t).workedMs, 0) / 60_000,
    );
    const shift = shiftFor(d);
    const scheduledTodayMinutes = shift === undefined ? 0 : (Date.parse(shift.end) - Date.parse(shift.start)) / 60_000 - 60;
    return {
      status: replay.status,
      ...(todays !== undefined ? { today: todays } : {}),
      events: events.filter((e) => localDateKey(new Date(e.occurredAt), TZ) >= (todays?.workDate ?? d)),
      exceptions: replay.exceptions,
      weekWorkedMinutes,
      scheduledTodayMinutes,
    };
  };

  const currentTimesheet = (): Timesheet => {
    const start = weekStart(today());
    const end = addDays(start, 6);
    const replay = replayAttendance(events, { timeZone: TZ, now: now() });
    const entries = replay.sessions
      .filter((s) => s.clockOut !== undefined && s.workDate >= start && s.workDate <= end)
      .map((s) => {
        const totals = sessionTotals(s, now());
        return { date: s.workDate, workedMinutes: Math.round(totals.workedMs / 60_000), breakMinutes: Math.round(totals.breakMs / 60_000) };
      });
    return { id: `ts_${start}`, organizationId: ORG, userId: me.id, teamId: TEAM, periodStart: start, periodEnd: end, entries, adjustments: [], ...timesheetState };
  };

  const evaluate = (input: TimeOffInput) => {
    const base = { organizationId: ORG, userId: me.id, start: input.start, end: input.end };
    const existing = requests.filter((r) => r.status === 'pending' || r.status === 'approved');
    const draft =
      input.kind === 'day_off'
        ? ({ ...base, kind: 'day_off' } as const)
        : ({ ...base, kind: 'leave', leaveTypeId: input.leaveTypeId ?? '', ...(input.halfDay !== undefined ? { halfDay: input.halfDay } : {}) } as const);
    const policy = POLICIES.find((p) => p.leaveTypeId === input.leaveTypeId);
    const balance = balances.find((b) => b.leaveTypeId === input.leaveTypeId);
    const result = evaluateTimeOff(draft, {
      today: today(),
      existing,
      ...(policy !== undefined ? { policy } : {}),
      ...(balance !== undefined ? { availableBalance: balance.available } : {}),
    });
    if (!result.ok) throw new ApiError(result.error.code, result.error.message);
    return result.value;
  };

  const respond = async <T>(fn: () => T): Promise<T> => {
    await delay(latency);
    return fn();
  };

  // ---------------------------------------------------------------- API
  return {
    session: () =>
      respond((): SessionInfo => {
        const s = subject();
        const role = options.getPersona();
        return {
          user: { ...me, title: TITLES[role] },
          organization: { id: ORG, name: 'Northwind Logistics', timeZone: TZ },
          role,
          modules: visibleModules(s, now()),
          widgets: homeWidgets(s, now()),
        };
      }),

    attendance: () =>
      respond(() => {
        ensure('attendance.view', mine);
        return snapshot();
      }),

    clock: (type, idempotencyKey) =>
      respond(() => {
        ensure('attendance.clock', mine);
        const candidate: AttendanceEvent = {
          id: nextId('evt'),
          idempotencyKey,
          organizationId: ORG,
          userId: me.id,
          type,
          occurredAt: now().toISOString(),
          source: 'mobile',
        };
        const result = recordEvent(events, candidate, { timeZone: TZ, now: now() });
        if (!result.ok) throw new ApiError(result.error.code, result.error.message);
        if (!result.value.duplicate) events = [...events, result.value.event];
        return snapshot();
      }),

    shifts: (from, to) =>
      respond(() => {
        ensure('schedule.view', mine);
        return dateRange(from, to).flatMap((d) => {
          const s = shiftFor(d);
          return s === undefined ? [] : [s];
        });
      }),

    tasks: () =>
      respond(() => {
        ensure('work.view', mine);
        return tasks;
      }),

    createTask: (input) =>
      respond(() => {
        ensure('work.create', mine);
        const title = input.title.trim();
        if (title.length === 0) throw new ApiError('invalid', 'Give the task a title.');
        const task: Task = {
          id: nextId('task'),
          title,
          status: 'todo',
          priority: input.priority,
          assigneeId: me.id,
          createdById: me.id,
          ...(input.due !== undefined ? { due: input.due } : {}),
        };
        tasks = [task, ...tasks];
        return task;
      }),

    setTaskDone: (id, done) =>
      respond(() => {
        ensure('work.view', mine);
        const task = tasks.find((t) => t.id === id);
        if (task === undefined) throw new ApiError('not_found', 'That task no longer exists.');
        const updated: Task = { ...task, status: done ? 'done' : 'todo' };
        tasks = tasks.map((t) => (t.id === id ? updated : t));
        return updated;
      }),

    balances: () =>
      respond(() => {
        ensure('timeoff.view', mine);
        return balances;
      }),

    timeOffRequests: () =>
      respond(() => {
        ensure('timeoff.view', mine);
        return [...requests].sort((a, b) => a.start.localeCompare(b.start));
      }),

    previewTimeOff: (input) => respond(() => evaluate(input)),

    requestTimeOff: (input) =>
      respond(() => {
        ensure('timeoff.request', mine);
        const evaluation = evaluate(input);
        const note = input.note?.trim();
        const request: TimeOffRequest = {
          id: nextId('req'),
          kind: input.kind,
          ...(input.kind === 'leave' && input.leaveTypeId !== undefined ? { leaveTypeId: input.leaveTypeId } : {}),
          start: input.start,
          end: input.end,
          days: evaluation.days,
          status: 'pending',
          ...(note !== undefined && note.length > 0 ? { note } : {}),
        };
        requests = [...requests, request];
        return request;
      }),

    approvals: () =>
      respond(() => {
        const s = subject();
        const visible = approvals.filter((a) => authorize(s, APPROVAL_PERMISSION[a.kind], a.resource, now()).allowed);
        return visible.map(({ resource: _resource, ...item }) => item);
      }),

    decide: (id, decision, reason) =>
      respond(() => {
        const item = approvals.find((a) => a.id === id);
        if (item === undefined) throw new ApiError('not_found', 'This request was already handled.');
        ensure(APPROVAL_PERMISSION[item.kind], item.resource);
        if (decision === 'return' && (reason === undefined || reason.trim().length === 0)) {
          throw new ApiError('reason_required', 'Add a short reason so they know what to fix.');
        }
        approvals = approvals.filter((a) => a.id !== id);
        tasks = tasks.map((t) => (t.link?.id === id ? { ...t, status: 'done' } : t));
      }),

    timesheet: () =>
      respond(() => {
        ensure('timesheet.view', mine);
        const sheet = currentTimesheet();
        return { ...sheet, actions: availableTimesheetActions(sheet, subject(), now()) };
      }),

    timesheetAction: (action: TimesheetAction, reason?: string) =>
      respond(() => {
        const result = transitionTimesheet(currentTimesheet(), action, subject(), {
          now: now(),
          ...(reason !== undefined ? { reason } : {}),
        });
        if (!result.ok) throw new ApiError(result.error.code, result.error.message);
        const { status, history, version } = result.value;
        timesheetState = { status, history, version };
      }),

    teamPulse: () =>
      respond(() => {
        ensure('reports.team', { organizationId: ORG, teamId: TEAM, departmentId: DEPT });
        return { onShift: 3, onBreak: 1, late: 1, off: 1, scheduled: 6 };
      }),
  };
}

/** Exposed for UI copy that needs the policy list (e.g. the request form). */
export const LEAVE_TYPES = POLICIES.map((p) => ({ id: p.leaveTypeId, name: p.name, allowHalfDays: p.allowHalfDays }));
