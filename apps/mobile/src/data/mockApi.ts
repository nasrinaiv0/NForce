import {
  DepartmentId,
  OrganizationId,
  PH_DEFAULT_PAY_POLICY,
  TeamId,
  UserId,
  addDays,
  authorize,
  authorizeOvertime,
  availableTimesheetActions,
  buildApprovalChain,
  classifySessions,
  currentApprovers,
  dateRange,
  decideApproval,
  evaluateTimeOff,
  homeWidgets,
  instantFromZoned,
  isoWeekday,
  localDateKey,
  managerChain,
  recordEvent,
  replayAttendance,
  sessionTotals,
  summarizePayLines,
  transitionTimesheet,
  visibleModules,
  weightedMinutes,
  type ApprovalState,
  type AttendanceEvent,
  type AttendanceEventType,
  type DateKey,
  type HolidayKind,
  type LeavePolicy,
  type OrgMember,
  type PayContext,
  type Permission,
  type ResourceContext,
  type RoleTemplate,
  type Subject,
  type Task,
  type Timesheet,
  type TimesheetStatus,
  type TimesheetTransitionRecord,
  type WorkSession,
} from '@nforce/core';

import {
  ApiError,
  type ApprovalItem,
  type ApprovalStepView,
  type AttendanceSnapshot,
  type LeaveBalance,
  type MemberStatus,
  type MyRequest,
  type NForceApi,
  type Person,
  type RequestKind,
  type RequestPayload,
  type SessionInfo,
  type Shift,
  type TeamMember,
  type TimeOffInput,
  type TimesheetDay,
  type TimesheetView,
} from './types';

/**
 * In-memory NForce backend for development, demos, previews and tests.
 *
 * It models a real reporting hierarchy (VP → Manager → Supervisors → Staff)
 * and is intentionally "honest": every read and write goes through the same
 * @nforce/core rules the server enforces (authorization with reporting-line
 * scope, idempotent attendance, leave policy, hierarchical approvals, the
 * timesheet state machine and pay classification). Swapping to the Supabase
 * client changes no screen code.
 */

export interface MockApiOptions {
  /** Demo profile; each maps to a different person in the hierarchy. */
  readonly getPersona: () => RoleTemplate;
  readonly now?: () => Date;
  readonly latencyMs?: number;
}

const ORG = OrganizationId('org_northwind');
const TZ = 'Asia/Manila';
const OPS = DepartmentId('dept_ops');
const PEOPLE_DEPT = DepartmentId('dept_people');
const FINANCE = DepartmentId('dept_finance');
const IT = DepartmentId('dept_it');
const CX = TeamId('team_cx');
const BILLING = TeamId('team_billing');

interface DirectoryPerson extends Person {
  readonly role: RoleTemplate;
  readonly managerId?: UserId;
  readonly teamId?: TeamId;
  readonly teamName?: string;
  readonly departmentId: DepartmentId;
  readonly restDays: readonly number[];
  readonly shift: { readonly start: [number, number]; readonly end: [number, number]; readonly night?: boolean };
  readonly location: string;
}

const initialsOf = (name: string) =>
  name
    .split(' ')
    .map((p) => p[0] ?? '')
    .join('')
    .slice(0, 2)
    .toUpperCase();

const DAY: DirectoryPerson['shift'] = { start: [9, 0], end: [18, 0] };
const EARLY: DirectoryPerson['shift'] = { start: [8, 0], end: [17, 0] };
const mk = (
  id: string,
  name: string,
  title: string,
  role: RoleTemplate,
  hue: number,
  extra: Partial<DirectoryPerson> & { departmentId: DepartmentId },
): DirectoryPerson => ({
  id: UserId(id),
  name,
  title,
  role,
  hue,
  initials: initialsOf(name),
  restDays: [6, 7],
  shift: DAY,
  location: 'Makati HQ · Floor 12',
  ...extra,
});

const cx = { departmentId: OPS, managerId: UserId('u_maya'), teamId: CX, teamName: 'Customer Success' };
const billing = { departmentId: OPS, managerId: UserId('u_kenji'), teamId: BILLING, teamName: 'Billing', shift: EARLY };

const DIRECTORY: readonly DirectoryPerson[] = [
  mk('u_rafael', 'Rafael Mendoza', 'VP, Operations', 'executive', 15, { departmentId: OPS }),
  mk('u_elena', 'Elena Cruz', 'Operations Manager', 'manager', 290, { departmentId: OPS, managerId: UserId('u_rafael') }),
  mk('u_maya', 'Maya Santos', 'Team Lead, Customer Success', 'supervisor', 230, { ...cx, managerId: UserId('u_elena') }),
  mk('u_kenji', 'Kenji Watanabe', 'Team Lead, Billing', 'supervisor', 190, { ...billing, managerId: UserId('u_elena') }),
  mk('u_jordan', 'Jordan Lee', 'Customer Success Specialist', 'staff', 200, cx),
  mk('u_priya', 'Priya Nair', 'Senior Specialist', 'staff', 330, cx),
  mk('u_diego', 'Diego Ramos', 'Night Support Specialist', 'staff', 25, { ...cx, shift: { start: [22, 0], end: [7, 0], night: true }, location: 'Remote' }),
  mk('u_aiko', 'Aiko Tanaka', 'Quality Analyst', 'staff', 160, { ...cx, restDays: [7, 1] }),
  mk('u_sam', 'Sam Okafor', 'Customer Success Specialist', 'staff', 270, cx),
  mk('u_lea', 'Lea Garcia', 'Billing Specialist', 'staff', 50, billing),
  mk('u_omar', 'Omar Haddad', 'Billing Specialist', 'staff', 120, billing),
  mk('u_nina', 'Nina Petrova', 'Collections Analyst', 'staff', 350, billing),
  mk('u_ivy', 'Ivy Chen', 'Workforce Planner', 'operations', 95, { departmentId: OPS, managerId: UserId('u_elena') }),
  mk('u_hana', 'Hana Yusuf', 'HR Business Partner', 'hr', 310, { departmentId: PEOPLE_DEPT, managerId: UserId('u_rafael') }),
  mk('u_paulo', 'Paulo Reyes', 'Payroll Specialist', 'payroll', 175, { departmentId: FINANCE, managerId: UserId('u_rafael') }),
  mk('u_alex', 'Alex Kim', 'Workspace Administrator', 'org_admin', 210, { departmentId: IT, managerId: UserId('u_rafael') }),
];

export const PERSONA_USER: Readonly<Record<RoleTemplate, UserId>> = {
  staff: UserId('u_jordan'),
  supervisor: UserId('u_maya'),
  manager: UserId('u_elena'),
  operations: UserId('u_ivy'),
  hr: UserId('u_hana'),
  payroll: UserId('u_paulo'),
  executive: UserId('u_rafael'),
  org_admin: UserId('u_alex'),
};

/** Statutory dates fixed by Philippine law; tenants manage their own calendar. */
export const DEMO_HOLIDAYS: Readonly<Record<string, { kind: HolidayKind; name: string }>> = {
  '2026-11-30': { kind: 'regular', name: 'Bonifacio Day' },
  '2026-12-08': { kind: 'special', name: 'Feast of the Immaculate Conception' },
  '2026-12-25': { kind: 'regular', name: 'Christmas Day' },
  '2026-12-30': { kind: 'regular', name: 'Rizal Day' },
  '2027-01-01': { kind: 'regular', name: "New Year's Day" },
};

const POLICIES: readonly LeavePolicy[] = [
  { leaveTypeId: 'vacation', name: 'Vacation', nonWorkingWeekdays: [6, 7], allowHalfDays: true, minNoticeDays: 3, maxConsecutiveDays: 15, allowNegativeBalance: false },
  { leaveTypeId: 'sick', name: 'Sick leave', nonWorkingWeekdays: [6, 7], allowHalfDays: true, minNoticeDays: 0, maxConsecutiveDays: 10, allowNegativeBalance: false },
  { leaveTypeId: 'wellness', name: 'Wellness day', nonWorkingWeekdays: [6, 7], allowHalfDays: false, minNoticeDays: 1, maxConsecutiveDays: 1, allowNegativeBalance: false },
];

const DECIDE_PERMISSION: Readonly<Record<RequestKind, Permission>> = {
  leave: 'timeoff.approve',
  day_off: 'timeoff.approve',
  overtime: 'timesheet.approve',
  timesheet: 'timesheet.approve',
  correction: 'attendance.correct',
};
const VIEW_PERMISSION: Readonly<Record<RequestKind, Permission>> = {
  leave: 'timeoff.view',
  day_off: 'timeoff.view',
  overtime: 'timesheet.view',
  timesheet: 'timesheet.view',
  correction: 'attendance.view',
};

interface RequestRecord {
  readonly id: string;
  readonly kind: RequestKind;
  readonly payload: RequestPayload;
  readonly submittedAt: string;
  state: ApprovalState;
}

const delay = (ms: number) => (ms > 0 ? new Promise<void>((r) => setTimeout(r, ms)) : Promise.resolve());
const hash = (s: string) => [...s].reduce((h, c) => (Math.imul(h, 31) + c.charCodeAt(0)) | 0, 7);

export function createMockApi(options: MockApiOptions): NForceApi {
  const now = options.now ?? (() => new Date());
  const latency = options.latencyMs ?? 300;
  let seq = 0;
  const nextId = (prefix: string) => `${prefix}_${(++seq).toString(36)}`;

  const byId = new Map(DIRECTORY.map((p) => [p.id, p]));
  const orgMembers = new Map<UserId, OrgMember>(
    DIRECTORY.map((p) => [p.id, { id: p.id, roles: [p.role], ...(p.managerId !== undefined ? { managerId: p.managerId } : {}) }]),
  );
  const person = (id: UserId): DirectoryPerson => {
    const p = byId.get(id);
    if (p === undefined) throw new ApiError('not_found', 'That person is not in this organization.');
    return p;
  };
  const view = (p: DirectoryPerson): Person => ({ id: p.id, name: p.name, title: p.title, initials: p.initials, hue: p.hue });
  const actor = (): DirectoryPerson => person(PERSONA_USER[options.getPersona()]);
  const subjectOf = (p: DirectoryPerson): Subject => ({
    userId: p.id,
    organizationId: ORG,
    status: 'active',
    roles: [p.role],
    teamIds: p.teamId !== undefined ? [p.teamId] : [],
    departmentId: p.departmentId,
    managerChain: chainOf(p),
  });
  const chainOf = (p: DirectoryPerson): UserId[] => {
    const r = managerChain(p.id, orgMembers);
    return r.ok ? r.value : [];
  };
  const resourceOf = (p: DirectoryPerson): ResourceContext => ({
    organizationId: ORG,
    subjectUserId: p.id,
    departmentId: p.departmentId,
    managerChain: chainOf(p),
    ...(p.teamId !== undefined ? { teamId: p.teamId } : {}),
  });
  const can = (permission: Permission, target: DirectoryPerson) => authorize(subjectOf(actor()), permission, resourceOf(target), now()).allowed;
  const ensure = (permission: Permission, target: DirectoryPerson) => {
    const d = authorize(subjectOf(actor()), permission, resourceOf(target), now());
    if (!d.allowed) throw new ApiError('forbidden', `You don't have access to this (${d.reason}).`);
  };

  const today = (): DateKey => localDateKey(now(), TZ);
  const at = (date: DateKey, h: number, m: number) => instantFromZoned(date, h, m, TZ).toISOString();
  const weekStart = (d: DateKey) => addDays(d, 1 - isoWeekday(d));
  const ago = (minutes: number) => new Date(now().getTime() - minutes * 60_000).toISOString();
  const plusMinutes = (iso: string, minutes: number) => new Date(Date.parse(iso) + minutes * 60_000).toISOString();
  const payCtx = (p: DirectoryPerson): PayContext => ({
    timeZone: TZ,
    policy: PH_DEFAULT_PAY_POLICY,
    isRestDay: (d) => p.restDays.includes(isoWeekday(d)),
    holidayOn: (d) => DEMO_HOLIDAYS[d]?.kind,
  });

  // ------------------------------------------------------------ schedules
  const onLeave = new Set<string>(); // `${userId}|${date}`
  const isScheduled = (p: DirectoryPerson, d: DateKey) =>
    !p.restDays.includes(isoWeekday(d)) && !onLeave.has(`${p.id}|${d}`) && DEMO_HOLIDAYS[d]?.kind !== 'regular';
  const shiftWindow = (p: DirectoryPerson, d: DateKey) => {
    const endDate = p.shift.night === true ? addDays(d, 1) : d;
    return { start: at(d, p.shift.start[0], p.shift.start[1]), end: at(endDate, p.shift.end[0], p.shift.end[1]) };
  };

  // ------------------------------------------------------------ attendance seed
  const events = new Map<UserId, AttendanceEvent[]>();
  const push = (p: DirectoryPerson, type: AttendanceEventType, occurredAt: string) => {
    if (Date.parse(occurredAt) > now().getTime()) return;
    const list = events.get(p.id) ?? [];
    list.push({ id: nextId('evt'), idempotencyKey: nextId('seed'), organizationId: ORG, userId: p.id, type, occurredAt, source: 'mobile' });
    events.set(p.id, list);
  };

  const seedToday = today();
  const lastWeek = addDays(weekStart(seedToday), -7);
  onLeave.add(`u_nina|${seedToday}`);

  for (const p of DIRECTORY) {
    for (const d of dateRange(lastWeek, seedToday)) {
      const key = `${p.id}|${d}`;
      const jitterIn = (Math.abs(hash(`${key}in`)) % 9) - 6; // −6…+2 min
      const jitterOut = Math.abs(hash(`${key}out`)) % 9; // 0…8 min
      // Scenario overrides that exercise every pay category.
      const restDayOt = p.id === 'u_jordan' && d === addDays(lastWeek, 5);
      if (!isScheduled(p, d) && !restDayOt) continue;
      if (p.id === 'u_lea' && d === seedToday) continue; // absent today

      const window = restDayOt ? { start: at(d, 9, 0), end: at(d, 19, 0) } : shiftWindow(p, d);
      const clockIn = p.id === 'u_sam' && d === seedToday ? plusMinutes(window.start, 24) : plusMinutes(window.start, jitterIn);
      let clockOut = plusMinutes(window.end, jitterOut);
      if (p.id === 'u_jordan' && d === addDays(lastWeek, 1)) clockOut = at(d, 20, 30); // ordinary OT
      if (p.id === 'u_priya' && d === addDays(lastWeek, 3)) clockOut = at(d, 22, 45); // OT into the night window
      if (p.id === 'u_omar' && d === addDays(lastWeek, 2)) clockOut = at(d, 20, 0);
      const missingOut = p.id === 'u_diego' && d === addDays(lastWeek, 4); // forgot to clock out

      push(p, 'clock_in', clockIn);
      if (p.shift.night === true) {
        push(p, 'break_start', at(addDays(d, 1), 2, 0));
        push(p, 'break_end', at(addDays(d, 1), 3, 0));
      } else {
        const lunchMinute = isoWeekday(d) % 2 === 0 ? 30 : 0;
        push(p, 'break_start', at(d, 12, lunchMinute));
        push(p, 'break_end', at(d, 13, lunchMinute));
      }
      if (!missingOut) push(p, 'clock_out', clockOut);
    }
  }

  const eventsOf = (id: UserId) => events.get(id) ?? [];
  const replayOf = (id: UserId) => replayAttendance(eventsOf(id), { timeZone: TZ, now: now() });

  // ------------------------------------------------------------ tasks, balances
  const tasks = new Map<UserId, Task[]>();
  const tasksOf = (p: DirectoryPerson): Task[] => {
    const existing = tasks.get(p.id);
    if (existing !== undefined) return existing;
    const t = (title: string, priority: Task['priority'], due?: number, status: Task['status'] = 'todo', link?: Task['link']): Task => ({
      id: nextId('task'),
      title,
      status,
      priority,
      assigneeId: p.id,
      createdById: p.managerId ?? p.id,
      ...(due !== undefined ? { due: addDays(seedToday, due) } : {}),
      ...(link !== undefined ? { link } : {}),
    });
    const list =
      p.role === 'staff'
        ? [
            t('Follow up on ticket #4821 escalation', 'high', -1),
            t('Update knowledge-base article on refunds', 'normal', 0),
            t('Submit last week’s timesheet', 'urgent', 0),
            t('Complete data privacy refresher', 'normal', 3),
            t('Shadow a Tier 3 call', 'low', 6),
            t('Read the new attendance policy', 'normal', -3, 'done'),
          ]
        : [
            t('Review Q4 coverage plan', 'high', -1),
            t('Clear pending approvals', 'urgent', 0, 'todo', { kind: 'approval', id: 'approvals', label: 'Approvals' }),
            t('Prepare shift handover notes', 'normal', 0, 'in_progress'),
            t('Complete data privacy refresher', 'normal', 3),
            t('1:1 coaching sessions', 'normal', 5),
            t('Collect holiday availability', 'low'),
            t('Submit November expense report', 'normal', -2, 'done'),
          ];
    tasks.set(p.id, list);
    return list;
  };

  const balances = new Map<UserId, LeaveBalance[]>();
  const balancesOf = (p: DirectoryPerson): LeaveBalance[] => {
    const existing = balances.get(p.id);
    if (existing !== undefined) return existing;
    const used = Math.abs(hash(p.id)) % 5;
    const list = [
      { leaveTypeId: 'vacation', name: 'Vacation', available: 12 - used - 0.5, entitled: 15, hue: 225 },
      { leaveTypeId: 'sick', name: 'Sick leave', available: 7 - (used % 3), entitled: 7, hue: 150 },
      { leaveTypeId: 'wellness', name: 'Wellness day', available: 2, entitled: 2, hue: 285 },
    ];
    balances.set(p.id, list);
    return list;
  };

  // ------------------------------------------------------------ requests
  const requests: RequestRecord[] = [];
  const submit = (requester: DirectoryPerson, payload: RequestPayload, submittedAt: string): RequestRecord => {
    const chain = buildApprovalChain(requester.id, orgMembers);
    if (!chain.ok) throw new ApiError(chain.error.code, chain.error.message);
    const record: RequestRecord = { id: nextId('req'), kind: payload.kind, payload, submittedAt, state: chain.value };
    requests.push(record);
    return record;
  };
  const seedDecide = (r: RequestRecord, by: string, decision: 'approve' | 'return', reason?: string) => {
    const result = decideApproval(r.state, UserId(by), decision, { now: now(), ...(reason !== undefined ? { reason } : {}) });
    if (result.ok) r.state = result.value;
  };

  const P = (id: string) => person(UserId(id));
  const leave = (start: number, end: number, type = 'vacation'): RequestPayload => ({
    kind: 'leave',
    leaveTypeId: type,
    leaveType: POLICIES.find((x) => x.leaveTypeId === type)?.name ?? type,
    start: addDays(seedToday, start),
    end: addDays(seedToday, end),
    days: end - start + 1,
  });
  const dayOff = (offset: number, note?: string): RequestPayload => ({
    kind: 'day_off',
    start: addDays(seedToday, offset),
    end: addDays(seedToday, offset),
    days: 1,
    ...(note !== undefined ? { note } : {}),
  });

  submit(P('u_jordan'), { kind: 'overtime', date: addDays(lastWeek, 1), minutes: 150, reason: 'Customer escalation backlog' }, ago(55));
  submit(P('u_priya'), leave(8, 10), ago(95));
  submit(P('u_diego'), { kind: 'correction', date: addDays(lastWeek, 4), requestedAt: at(addDays(lastWeek, 5), 7, 4), note: 'Forgot to clock out after the night shift' }, ago(130));
  submit(P('u_priya'), { kind: 'overtime', date: addDays(lastWeek, 3), minutes: 225, reason: 'Month-end ticket surge' }, ago(200));
  seedDecide(submit(P('u_aiko'), dayOff(12, 'Family event'), ago(320)), 'u_maya', 'approve');
  submit(P('u_lea'), leave(15, 16), ago(240));
  seedDecide(submit(P('u_omar'), { kind: 'overtime', date: addDays(lastWeek, 2), minutes: 120, reason: 'Invoice run' }, ago(400)), 'u_kenji', 'approve');
  submit(P('u_kenji'), dayOff(6), ago(600));
  submit(P('u_maya'), leave(20, 21), ago(700));
  submit(P('u_elena'), leave(30, 32), ago(900));
  const approvedDayOff = submit(P('u_jordan'), dayOff(10, 'Graduation'), ago(2880));
  seedDecide(approvedDayOff, 'u_maya', 'approve');
  seedDecide(approvedDayOff, 'u_elena', 'approve');
  seedDecide(submit(P('u_nina'), leave(4, 5), ago(1500)), 'u_kenji', 'return', 'Overlaps with month-end close');

  // ------------------------------------------------------------ timesheets
  type SheetState = { status: TimesheetStatus; history: TimesheetTransitionRecord[]; version: number };
  const sheetState = new Map<string, SheetState>();
  const sheetKey = (id: UserId, start: DateKey) => `${id}|${start}`;
  const stateOf = (id: UserId, start: DateKey): SheetState => sheetState.get(sheetKey(id, start)) ?? { status: 'draft', history: [], version: 1 };

  const sessionsIn = (p: DirectoryPerson, start: DateKey, end: DateKey) =>
    replayOf(p.id).sessions.filter((s) => s.workDate >= start && s.workDate <= end);

  const sheetFor = (p: DirectoryPerson, start: DateKey): Timesheet => {
    const end = addDays(start, 6);
    const entries = sessionsIn(p, start, end)
      .filter((s) => s.clockOut !== undefined)
      .map((s) => {
        const totals = sessionTotals(s, now());
        return { date: s.workDate, workedMinutes: Math.round(totals.workedMs / 60_000), breakMinutes: Math.round(totals.breakMs / 60_000) };
      });
    return {
      id: `ts_${p.id}_${start}`,
      organizationId: ORG,
      userId: p.id,
      ...(p.teamId !== undefined ? { teamId: p.teamId } : {}),
      departmentId: p.departmentId,
      managerChain: chainOf(p),
      periodStart: start,
      periodEnd: end,
      entries,
      adjustments: [],
      ...stateOf(p.id, start),
    };
  };

  const overtimeRequests = (p: DirectoryPerson, date: DateKey) =>
    requests.filter((r) => r.state.requesterId === p.id && r.payload.kind === 'overtime' && r.payload.date === date);
  const otMinutes = (rs: RequestRecord[], status: ApprovalState['status']) =>
    rs.filter((r) => r.state.status === status).reduce((n, r) => n + (r.payload.kind === 'overtime' ? r.payload.minutes : 0), 0);

  const classify = (p: DirectoryPerson, start: DateKey): TimesheetDay[] => {
    const sessions = sessionsIn(p, start, addDays(start, 6));
    return classifySessions(sessions, payCtx(p)).map((day) => {
      const rs = overtimeRequests(p, day.date);
      const breakMinutes = sessions
        .filter((s: WorkSession) => s.workDate === day.date)
        .reduce((n, s) => n + Math.round(sessionTotals(s, now()).breakMs / 60_000), 0);
      const holiday = DEMO_HOLIDAYS[day.date];
      return {
        ...day,
        overtime: authorizeOvertime(day, otMinutes(rs, 'approved')),
        pendingOvertimeMinutes: otMinutes(rs, 'pending'),
        breakMinutes,
        ...(holiday !== undefined ? { holidayName: holiday.name } : {}),
      };
    });
  };

  const seedSheet = (id: string, to: TimesheetStatus, by: string) =>
    sheetState.set(sheetKey(UserId(id), lastWeek), {
      status: to,
      version: 2,
      history: [{ action: to === 'approved' ? 'approve' : 'submit', from: 'draft', to, by: UserId(by), at: ago(2000) }],
    });
  seedSheet('u_jordan', 'approved', 'u_elena');
  seedSheet('u_sam', 'submitted', 'u_sam');
  submit(P('u_sam'), { kind: 'timesheet', periodStart: lastWeek, minutes: 40 * 60 + 35, overtimeMinutes: 35 }, ago(1440));

  // ------------------------------------------------------------ views
  const stepViews = (s: ApprovalState): ApprovalStepView[] =>
    s.steps.map((st) => ({
      level: st.level,
      approver: view(person(st.approverId)),
      status: st.status,
      ...(st.decidedAt !== undefined ? { decidedAt: st.decidedAt } : {}),
      ...(st.reason !== undefined ? { reason: st.reason } : {}),
    }));

  const canDecideRecord = (r: RequestRecord, me: DirectoryPerson) =>
    currentApprovers(r.state).includes(me.id) && can(DECIDE_PERMISSION[r.kind], person(r.state.requesterId));

  const toItem = (r: RequestRecord, me: DirectoryPerson): ApprovalItem => {
    const requester = person(r.state.requesterId);
    const decidable = canDecideRecord(r, me);
    const current = r.state.steps.find((s) => s.status === 'pending');
    return {
      id: r.id,
      kind: r.kind,
      payload: r.payload,
      requester: view(requester),
      ...(requester.teamName !== undefined ? { teamName: requester.teamName } : {}),
      submittedAt: r.submittedAt,
      status: r.state.status,
      steps: stepViews(r.state),
      canDecide: decidable,
      ...(decidable ? { actingAs: current?.approverId === me.id ? current.level : ('manager' as const) } : {}),
    };
  };

  const toMyRequest = (r: RequestRecord): MyRequest => ({
    id: r.id,
    kind: r.kind,
    payload: r.payload,
    status: r.state.status,
    submittedAt: r.submittedAt,
    steps: stepViews(r.state),
  });

  const memberStatus = (p: DirectoryPerson) => {
    const d = today();
    const replay = replayOf(p.id);
    const session = replay.sessions.find((s) => s.clockOut === undefined) ?? [...replay.sessions].reverse().find((s) => s.workDate === d);
    const isToday = session !== undefined && session.workDate === d;
    const todayMinutes = session !== undefined && (isToday || session.clockOut === undefined) ? Math.floor(sessionTotals(session, now()).workedMs / 60_000) : 0;
    const scheduled = isScheduled(p, d);
    const window = shiftWindow(p, d);
    const late = isToday && scheduled ? Math.round((Date.parse(session.clockIn) - Date.parse(window.start)) / 60_000) : 0;
    const extra = {
      todayMinutes,
      ...(session !== undefined && (isToday || session.clockOut === undefined) ? { clockIn: session.clockIn } : {}),
      ...(late > 5 ? { lateByMinutes: late } : {}),
    };
    const withStatus = (status: MemberStatus) => ({ status, ...extra });
    // An open session past the max shift length is a missed clock-out, not "working".
    if (session !== undefined && session.clockOut === undefined && replay.exceptions.some((x) => x.kind === 'missed_clock_out' && x.at === session.clockIn)) {
      return { status: 'missed_punch' as const, todayMinutes: 0, clockIn: session.clockIn };
    }
    if (replay.status === 'working' || replay.status === 'on_break') return withStatus(replay.status);
    if (isToday) return withStatus('done');
    if (!scheduled) return withStatus('off');
    const t = now().getTime();
    if (t < Date.parse(window.start) + 5 * 60_000) return withStatus('not_started');
    if (t < Date.parse(window.end)) return withStatus('late');
    return withStatus('absent');
  };

  const teamOf = (me: DirectoryPerson): TeamMember[] => {
    const ws = weekStart(today());
    return DIRECTORY.filter((p) => p.id !== me.id && can('attendance.view', p)).map((p) => {
      const days = classifySessions(sessionsIn(p, ws, addDays(ws, 6)), payCtx(p));
      const open = replayOf(p.id).sessions.find((s) => s.clockOut === undefined && s.workDate >= ws);
      const openMinutes = open !== undefined ? Math.floor(sessionTotals(open, now()).workedMs / 60_000) : 0;
      const manager = p.managerId !== undefined ? byId.get(p.managerId) : undefined;
      return {
        person: view(p),
        role: p.role,
        ...(p.teamName !== undefined ? { teamName: p.teamName } : {}),
        ...(manager !== undefined ? { managerName: manager.name } : {}),
        ...memberStatus(p),
        weekMinutes: days.reduce((n, d) => n + d.workedMinutes, 0) + openMinutes,
        weekOvertimeMinutes: days.reduce((n, d) => n + d.overtimeMinutes, 0),
        weekNightMinutes: days.reduce((n, d) => n + d.nightMinutes, 0),
        pendingRequests: requests.filter((r) => r.state.requesterId === p.id && r.state.status === 'pending').length,
      };
    });
  };

  const snapshot = (p: DirectoryPerson): AttendanceSnapshot => {
    const t = now();
    const replay = replayOf(p.id);
    const d = today();
    const open = replay.sessions.find((s) => s.clockOut === undefined);
    const todays = open ?? [...replay.sessions].reverse().find((s) => s.workDate === d);
    const ws = weekStart(d);
    const weekWorkedMinutes = Math.floor(
      replay.sessions.filter((s) => s.workDate >= ws).reduce((sum, s) => sum + sessionTotals(s, t).workedMs, 0) / 60_000,
    );
    const window = shiftWindow(p, d);
    const scheduledTodayMinutes = isScheduled(p, d) ? (Date.parse(window.end) - Date.parse(window.start)) / 60_000 - 60 : 0;
    return {
      status: replay.status,
      ...(todays !== undefined ? { today: todays } : {}),
      events: todays === undefined ? [] : eventsOf(p.id).filter((e) => Date.parse(e.occurredAt) >= Date.parse(todays.clockIn)),
      exceptions: replay.exceptions.filter((x) => Date.parse(x.at) >= Date.parse(at(ws, 0, 0))),
      weekWorkedMinutes,
      scheduledTodayMinutes,
    };
  };

  const evaluate = (me: DirectoryPerson, input: TimeOffInput) => {
    const base = { organizationId: ORG, userId: me.id, start: input.start, end: input.end };
    const existing = requests
      .filter((r) => r.state.requesterId === me.id && r.state.status !== 'returned')
      .flatMap((r) => (r.payload.kind === 'leave' || r.payload.kind === 'day_off' ? [{ start: r.payload.start, end: r.payload.end }] : []));
    const draft =
      input.kind === 'day_off'
        ? ({ ...base, kind: 'day_off' } as const)
        : ({ ...base, kind: 'leave', leaveTypeId: input.leaveTypeId ?? '', ...(input.halfDay !== undefined ? { halfDay: input.halfDay } : {}) } as const);
    const policy = POLICIES.find((p) => p.leaveTypeId === input.leaveTypeId);
    const balance = balancesOf(me).find((b) => b.leaveTypeId === input.leaveTypeId);
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

  // ------------------------------------------------------------ API
  return {
    session: () =>
      respond((): SessionInfo => {
        const me = actor();
        const s = subjectOf(me);
        const manager = me.managerId !== undefined ? byId.get(me.managerId) : undefined;
        return {
          user: view(me),
          organization: { id: ORG, name: 'Northwind Logistics', timeZone: TZ },
          role: me.role,
          ...(me.teamName !== undefined ? { teamName: me.teamName } : {}),
          ...(manager !== undefined ? { manager: view(manager) } : {}),
          modules: visibleModules(s, now()),
          widgets: homeWidgets(s, now()),
          payPolicy: PH_DEFAULT_PAY_POLICY,
        };
      }),

    attendance: () =>
      respond(() => {
        const me = actor();
        ensure('attendance.view', me);
        return snapshot(me);
      }),

    clock: (type, idempotencyKey) =>
      respond(() => {
        const me = actor();
        ensure('attendance.clock', me);
        const candidate: AttendanceEvent = { id: nextId('evt'), idempotencyKey, organizationId: ORG, userId: me.id, type, occurredAt: now().toISOString(), source: 'mobile' };
        const result = recordEvent(eventsOf(me.id), candidate, { timeZone: TZ, now: now() });
        if (!result.ok) throw new ApiError(result.error.code, result.error.message);
        if (!result.value.duplicate) events.set(me.id, [...eventsOf(me.id), result.value.event]);
        return snapshot(me);
      }),

    shifts: (from, to) =>
      respond(() => {
        const me = actor();
        ensure('schedule.view', me);
        return dateRange(from, to).flatMap((d): Shift[] => {
          if (!isScheduled(me, d)) return [];
          const w = shiftWindow(me, d);
          const holiday = DEMO_HOLIDAYS[d];
          const crew = DIRECTORY.filter((p) => p.id !== me.id && p.teamId !== undefined && p.teamId === me.teamId && isScheduled(p, d)).slice(0, 4);
          return [
            {
              id: `shift_${me.id}_${d}`,
              date: d,
              start: w.start,
              end: w.end,
              role: me.teamName ?? me.title,
              location: me.location,
              night: me.shift.night === true,
              ...(holiday !== undefined ? { holiday } : {}),
              teammates: crew.map(view),
            },
          ];
        });
      }),

    tasks: () =>
      respond(() => {
        const me = actor();
        ensure('work.view', me);
        return tasksOf(me);
      }),

    createTask: (input) =>
      respond(() => {
        const me = actor();
        ensure('work.create', me);
        const title = input.title.trim();
        if (title.length === 0) throw new ApiError('invalid', 'Give the task a title.');
        const task: Task = { id: nextId('task'), title, status: 'todo', priority: input.priority, assigneeId: me.id, createdById: me.id, ...(input.due !== undefined ? { due: input.due } : {}) };
        tasks.set(me.id, [task, ...tasksOf(me)]);
        return task;
      }),

    setTaskDone: (id, done) =>
      respond(() => {
        const me = actor();
        ensure('work.view', me);
        const list = tasksOf(me);
        const task = list.find((t) => t.id === id);
        if (task === undefined) throw new ApiError('not_found', 'That task no longer exists.');
        const updated: Task = { ...task, status: done ? 'done' : 'todo' };
        tasks.set(me.id, list.map((t) => (t.id === id ? updated : t)));
        return updated;
      }),

    balances: () =>
      respond(() => {
        const me = actor();
        ensure('timeoff.view', me);
        return balancesOf(me);
      }),

    myRequests: () =>
      respond(() => {
        const me = actor();
        return requests
          .filter((r) => r.state.requesterId === me.id)
          .map(toMyRequest)
          .sort((a, b) => b.submittedAt.localeCompare(a.submittedAt));
      }),

    previewTimeOff: (input) => respond(() => evaluate(actor(), input)),

    requestTimeOff: (input) =>
      respond(() => {
        const me = actor();
        ensure('timeoff.request', me);
        const evaluation = evaluate(me, input);
        const note = input.note?.trim();
        const withNote = note !== undefined && note.length > 0 ? { note } : {};
        const payload: RequestPayload =
          input.kind === 'day_off'
            ? { kind: 'day_off', start: input.start, end: input.end, days: evaluation.days, ...withNote }
            : {
                kind: 'leave',
                leaveTypeId: input.leaveTypeId ?? '',
                leaveType: POLICIES.find((p) => p.leaveTypeId === input.leaveTypeId)?.name ?? '',
                start: input.start,
                end: input.end,
                days: evaluation.days,
                ...withNote,
              };
        return toMyRequest(submit(me, payload, now().toISOString()));
      }),

    requestOvertime: (input) =>
      respond(() => {
        const me = actor();
        ensure('timesheet.submit', me);
        const reason = input.reason.trim();
        if (!Number.isInteger(input.minutes) || input.minutes < 15 || input.minutes > 720) {
          throw new ApiError('invalid', 'Overtime must be between 15 minutes and 12 hours.');
        }
        if (input.date > today()) throw new ApiError('invalid', 'File overtime after it is worked.');
        if (reason.length === 0) throw new ApiError('reason_required', 'Add a short reason for the overtime.');
        return toMyRequest(submit(me, { kind: 'overtime', date: input.date, minutes: input.minutes, reason }, now().toISOString()));
      }),

    approverPreview: () =>
      respond(() => {
        const chain = buildApprovalChain(actor().id, orgMembers);
        if (!chain.ok) throw new ApiError(chain.error.code, chain.error.message);
        return stepViews(chain.value);
      }),

    approvals: () =>
      respond(() => {
        const me = actor();
        return requests
          .filter((r) => {
            if (r.state.requesterId === me.id) return false;
            const inChain = r.state.steps.some((s) => s.approverId === me.id);
            return inChain || can(VIEW_PERMISSION[r.kind], person(r.state.requesterId));
          })
          .map((r) => toItem(r, me));
      }),

    decide: (id, decision, reason) =>
      respond(() => {
        const me = actor();
        const r = requests.find((x) => x.id === id);
        if (r === undefined) throw new ApiError('not_found', 'This request no longer exists.');
        const requester = person(r.state.requesterId);
        if (r.state.status === 'pending' && currentApprovers(r.state).includes(me.id)) ensure(DECIDE_PERMISSION[r.kind], requester);
        const result = decideApproval(r.state, me.id, decision, { now: now(), ...(reason !== undefined ? { reason } : {}) });
        if (!result.ok) throw new ApiError(result.error.code, result.error.message);

        // Validate dependent records BEFORE committing, so a decision is never half-applied.
        const p0 = r.payload;
        let sheetUpdate: SheetState | undefined;
        if (p0.kind === 'timesheet' && result.value.status !== 'pending') {
          const t = transitionTimesheet(sheetFor(requester, p0.periodStart), result.value.status === 'approved' ? 'approve' : 'return', subjectOf(me), {
            now: now(),
            ...(reason !== undefined ? { reason } : {}),
          });
          if (!t.ok) throw new ApiError(t.error.code, t.error.message);
          sheetUpdate = { status: t.value.status, history: [...t.value.history], version: t.value.version };
        }
        r.state = result.value;
        if (sheetUpdate !== undefined && p0.kind === 'timesheet') sheetState.set(sheetKey(requester.id, p0.periodStart), sheetUpdate);

        // Effects of a FINAL decision on the authoritative records.
        const p = r.payload;
        const approved = r.state.status === 'approved';
        if (approved && p.kind === 'leave') {
          balances.set(requester.id, balancesOf(requester).map((b) => (b.leaveTypeId === p.leaveTypeId ? { ...b, available: b.available - p.days } : b)));
        }
        if (approved && (p.kind === 'leave' || p.kind === 'day_off')) {
          for (const d of dateRange(p.start, p.end)) onLeave.add(`${requester.id}|${d}`);
        }
        if (approved && p.kind === 'correction') {
          events.set(requester.id, [
            ...eventsOf(requester.id),
            { id: nextId('evt'), idempotencyKey: nextId('corr'), organizationId: ORG, userId: requester.id, type: 'clock_out', occurredAt: p.requestedAt, source: 'correction', note: p.note },
          ]);
        }
      }),

    timesheet: (params = {}) =>
      respond((): TimesheetView => {
        const me = actor();
        const target = person(params.userId ?? me.id);
        ensure('timesheet.view', target);
        let start = params.periodStart ?? weekStart(today());
        // A week that just started has nothing payable yet: open last week instead.
        if (params.periodStart === undefined && classify(target, start).length === 0) start = addDays(start, -7);
        const days = classify(target, start);
        const sheet = sheetFor(target, start);
        const actions = availableTimesheetActions(sheet, subjectOf(me), now()).filter((a) => (target.id === me.id ? a === 'submit' : a === 'lock'));
        const summary = summarizePayLines(days);
        const sum = (f: (d: TimesheetDay) => number) => days.reduce((n, d) => n + f(d), 0);
        return {
          person: view(target),
          isMine: target.id === me.id,
          periodStart: start,
          periodEnd: addDays(start, 6),
          status: sheet.status,
          actions,
          days,
          summary,
          totals: {
            worked: sum((d) => d.workedMinutes),
            regular: sum((d) => d.regularMinutes),
            overtime: sum((d) => d.overtimeMinutes),
            approvedOvertime: sum((d) => d.overtime.approvedMinutes),
            night: sum((d) => d.nightMinutes),
            restDay: sum((d) => (d.restDay ? d.workedMinutes : 0)),
            holiday: sum((d) => (d.holiday !== undefined ? d.workedMinutes : 0)),
            weighted: weightedMinutes(summary),
          },
          history: sheet.history,
        };
      }),

    timesheetAction: (action, periodStart, reason) =>
      respond(() => {
        const me = actor();
        if (action !== 'submit') throw new ApiError('invalid', 'Timesheets are approved from the Approvals inbox.');
        const result = transitionTimesheet(sheetFor(me, periodStart), 'submit', subjectOf(me), { now: now(), ...(reason !== undefined ? { reason } : {}) });
        if (!result.ok) throw new ApiError(result.error.code, result.error.message);
        const days = classify(me, periodStart);
        submit(
          me,
          {
            kind: 'timesheet',
            periodStart,
            minutes: days.reduce((n, d) => n + d.workedMinutes, 0),
            overtimeMinutes: days.reduce((n, d) => n + d.overtimeMinutes, 0),
          },
          now().toISOString(),
        );
        sheetState.set(sheetKey(me.id, periodStart), { status: result.value.status, history: [...result.value.history], version: result.value.version });
      }),

    team: () => respond(() => teamOf(actor())),

    teamPulse: () =>
      respond(() => {
        const me = actor();
        if (!authorize(subjectOf(me), 'reports.team', { organizationId: ORG, departmentId: me.departmentId }, now()).allowed) {
          throw new ApiError('forbidden', "You don't have access to team reports.");
        }
        // Person-level scope when granted; otherwise an org-wide aggregate (counts only).
        const scoped = teamOf(me);
        const statuses = scoped.length > 0 ? scoped.map((m) => m.status) : DIRECTORY.filter((p) => p.id !== me.id).map((p) => memberStatus(p).status);
        const count = (...xs: MemberStatus[]) => statuses.filter((x) => xs.includes(x)).length;
        return {
          onShift: count('working'),
          // Missed punches need a correction; surface them with late/absent.
          onBreak: count('on_break'),
          late: count('late', 'absent', 'missed_punch'),
          off: count('off', 'not_started', 'done'),
          scheduled: statuses.length - count('off'),
        };
      }),
  };
}

/** Exposed for UI copy that needs the policy list (e.g. the request form). */
export const LEAVE_TYPES = POLICIES.map((p) => ({ id: p.leaveTypeId, name: p.name, allowHalfDays: p.allowHalfDays }));
