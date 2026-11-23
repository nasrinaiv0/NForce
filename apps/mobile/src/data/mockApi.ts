import {
  DepartmentId,
  OrganizationId,
  PH_DEFAULT_PAY_POLICY,
  TeamId,
  UserId,
  addDays,
  approvalSla,
  assignableRoles,
  authorize,
  canAssignRole,
  planOffboarding,
  authorizeOvertime,
  buildDayRecord,
  buildPayrollRegister,
  dailyRates,
  grantScope,
  moveDeal as moveDealRule,
  summarizeAttendance,
  summarizeBy,
  weeklyTrend,
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
  type DayRecord,
  type Deal,
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
  type AdminOverview,
  type AttendanceFlag,
  type AttendanceReport,
  type AuditEntry,
  type DirectoryEntry,
  type ExecutiveReport,
  type NotificationItem,
  type PayrollView,
  type PersonProfile,
  type ReportScope,
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
const EXEC = DepartmentId('dept_exec');
const DEPARTMENT_NAMES: Readonly<Record<string, string>> = {
  dept_ops: 'Operations',
  dept_people: 'People',
  dept_finance: 'Finance',
  dept_it: 'IT',
  dept_exec: 'Executive Office',
};
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
  mk('u_sofia', 'Sofia Reyes', 'CEO · Organization Owner', 'owner', 255, { departmentId: EXEC }),
  mk('u_rafael', 'Rafael Mendoza', 'VP, Operations', 'executive', 15, { departmentId: OPS, managerId: UserId('u_sofia') }),
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
  owner: UserId('u_sofia'),
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

  /** Mutable copy: people can be added, edited and offboarded. */
  const allPeople: DirectoryPerson[] = [...DIRECTORY];
  const offboarded = new Set<UserId>();
  const byId = new Map(allPeople.map((p) => [p.id, p]));
  const orgMembers = new Map<UserId, OrgMember>();
  const rebuildOrg = () => {
    orgMembers.clear();
    for (const p of allPeople) {
      if (offboarded.has(p.id)) continue;
      orgMembers.set(p.id, { id: p.id, roles: [p.role], ...(p.managerId !== undefined ? { managerId: p.managerId } : {}) });
    }
  };
  rebuildOrg();
  const people = (): DirectoryPerson[] => allPeople.filter((p) => !offboarded.has(p.id));
  const replacePerson = (next: DirectoryPerson) => {
    const i = allPeople.findIndex((p) => p.id === next.id);
    if (i >= 0) allPeople[i] = next;
    else allPeople.push(next);
    byId.set(next.id, next);
    rebuildOrg();
  };
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
  /** Nine full weeks of history feed reports and trends. */
  const HISTORY_WEEKS = 9;
  const historyStart = addDays(weekStart(seedToday), -7 * HISTORY_WEEKS);
  onLeave.add(`u_nina|${seedToday}`);
  const historicalOvertime: { p: DirectoryPerson; date: DateKey; minutes: number }[] = [];

  for (const p of people()) {
    for (const d of dateRange(historyStart, seedToday)) {
      const key = `${p.id}|${d}`;
      const jitterIn = (Math.abs(hash(`${key}in`)) % 9) - 6; // −6…+2 min
      const jitterOut = Math.abs(hash(`${key}out`)) % 9; // 0…8 min
      // Older weeks: realistic sick days, no-shows, late arrivals and approved OT,
      // with punctuality improving over time (a trend worth reporting).
      if (d < lastWeek && !p.restDays.includes(isoWeekday(d)) && DEMO_HOLIDAYS[d]?.kind !== 'regular') {
        const h = Math.abs(hash(`${key}hist`));
        const weeksAgo = Math.floor((Date.parse(lastWeek) - Date.parse(d)) / (7 * 86_400_000));
        if ((p.role === 'staff' || p.role === 'supervisor') && h % 19 === 0) {
          onLeave.add(key); // sick leave
          continue;
        }
        if (p.role === 'staff' && h % 29 === 7) continue; // unexcused absence
        const window = shiftWindow(p, d);
        const lateEvery = weeksAgo >= 5 ? 9 : weeksAgo >= 3 ? 14 : 23;
        const clockIn = h % lateEvery === 0 ? plusMinutes(window.start, 8 + (h % 27)) : plusMinutes(window.start, jitterIn);
        const otMinutes = (p.role === 'staff' || p.role === 'supervisor') && h % 8 === 3 ? 45 + (h % 7) * 15 : 0;
        push(p, 'clock_in', clockIn);
        if (p.shift.night === true) {
          push(p, 'break_start', at(addDays(d, 1), 2, 0));
          push(p, 'break_end', at(addDays(d, 1), 3, 0));
        } else {
          push(p, 'break_start', at(d, 12, 0));
          push(p, 'break_end', at(d, 13, 0));
        }
        push(p, 'clock_out', plusMinutes(window.end, otMinutes > 0 ? otMinutes : jitterOut));
        if (otMinutes > 0) historicalOvertime.push({ p, date: d, minutes: otMinutes });
        continue;
      }
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

  // ------------------------------------------------------------ audit
  const auditLog: { id: string; at: string; actorId: UserId; action: string; detail: string }[] = [];
  const audit = (actorId: UserId, action: string, detail: string, at = now().toISOString()) =>
    auditLog.push({ id: nextId('aud'), at, actorId, action, detail });

  // ------------------------------------------------------------ requests
  const requests: RequestRecord[] = [];
  const submit = (requester: DirectoryPerson, payload: RequestPayload, submittedAt: string): RequestRecord => {
    const chain = buildApprovalChain(requester.id, orgMembers);
    if (!chain.ok) throw new ApiError(chain.error.code, chain.error.message);
    const record: RequestRecord = { id: nextId('req'), kind: payload.kind, payload, submittedAt, state: chain.value };
    requests.push(record);
    audit(requester.id, 'request.submitted', payload.kind, submittedAt);
    return record;
  };
  const seedDecide = (r: RequestRecord, by: string, decision: 'approve' | 'return', reason?: string, when: Date = now()) => {
    const result = decideApproval(r.state, UserId(by), decision, { now: when, ...(reason !== undefined ? { reason } : {}) });
    if (result.ok) {
      r.state = result.value;
      audit(UserId(by), `request.${decision}`, r.kind, when.toISOString());
    }
  };
  // Historical overtime: filed the next morning, decided along the chain within hours.
  for (const ot of historicalOvertime) {
    const filed = new Date(Date.parse(at(addDays(ot.date, 1), 9, 30)));
    const r = submit(ot.p, { kind: 'overtime', date: ot.date, minutes: ot.minutes, reason: 'Queue coverage' }, filed.toISOString());
    let t = filed.getTime();
    for (const step of r.state.steps) {
      t += (2 + (Math.abs(hash(r.id)) % 20)) * 3_600_000;
      seedDecide(r, step.approverId, 'approve', undefined, new Date(t));
    }
  }

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
  for (const p of people()) {
    if (!['u_sam', 'u_priya', 'u_diego'].includes(p.id)) seedSheet(p.id, 'approved', p.managerId ?? p.id);
    for (let w = 2; w <= HISTORY_WEEKS; w++) {
      sheetState.set(sheetKey(p.id, addDays(lastWeek, -7 * (w - 1))), {
        status: 'locked',
        version: 4,
        history: [{ action: 'lock', from: 'approved', to: 'locked', by: UserId('u_paulo'), at: ago(2000 + w * 10_080) }],
      });
    }
  }
  seedSheet('u_sam', 'submitted', 'u_sam');
  const lockedPeriods = new Set<DateKey>(Array.from({ length: HISTORY_WEEKS - 1 }, (_, i) => addDays(lastWeek, -7 * (i + 1))));
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

  /** Organization owners (org.manage) may decide any request at any stage. */
  const isOwner = (me: DirectoryPerson) => authorize(subjectOf(me), 'org.manage', { organizationId: ORG }, now()).allowed;
  const canDecideRecord = (r: RequestRecord, me: DirectoryPerson) =>
    r.state.status === 'pending' &&
    r.state.requesterId !== me.id &&
    (currentApprovers(r.state).includes(me.id) || isOwner(me)) &&
    can(DECIDE_PERMISSION[r.kind], person(r.state.requesterId));

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
    return people().filter((p) => p.id !== me.id && can('attendance.view', p)).map((p) => {
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


  // ------------------------------------------------------------ reporting
  const isWorkday = (p: DirectoryPerson, d: DateKey) => !p.restDays.includes(isoWeekday(d)) && DEMO_HOLIDAYS[d]?.kind !== 'regular';
  const groupName = (p: DirectoryPerson) => p.teamName ?? DEPARTMENT_NAMES[p.departmentId] ?? p.departmentId;

  /** One record per person per day: the single source for every attendance report. */
  const recordsFor = (p: DirectoryPerson, from: DateKey, to: DateKey): DayRecord[] => {
    const replay = replayOf(p.id);
    const sessions = replay.sessions.filter((x) => x.workDate >= from && x.workDate <= to);
    const classified = new Map(classifySessions(sessions, payCtx(p)).map((d) => [d.date, d]));
    return dateRange(from, to).map((d) => {
      const session = sessions.find((x) => x.workDate === d);
      const missed =
        session !== undefined && session.clockOut === undefined && replay.exceptions.some((x) => x.kind === 'missed_clock_out' && x.at === session.clockIn);
      const holiday = DEMO_HOLIDAYS[d]?.kind;
      const c = classified.get(d);
      return buildDayRecord({
        userId: p.id,
        date: d,
        ...(isWorkday(p, d) ? { scheduledStart: shiftWindow(p, d).start } : {}),
        onLeave: onLeave.has(`${p.id}|${d}`),
        ...(holiday !== undefined ? { holiday } : {}),
        ...(session !== undefined ? { clockIn: session.clockIn } : {}),
        ...(c !== undefined ? { classified: c } : {}),
        missedPunch: missed,
      });
    });
  };

  /** Completed days only: reports end yesterday; today is live in the Team view. */
  const periodFor = (weeks: number) => {
    const to = addDays(today(), -1);
    const from = addDays(to, -7 * weeks + 1);
    return { from, to, prevFrom: addDays(from, -7 * weeks), prevTo: addDays(from, -1) };
  };
  const trendStarts = (n = 8) => {
    const lastComplete = addDays(weekStart(today()), -7);
    return Array.from({ length: n }, (_, i) => addDays(lastComplete, -7 * (n - 1 - i)));
  };
  const scopedPeople = (me: DirectoryPerson) => people().filter((p) => p.id !== me.id && can('attendance.view', p));
  const hasOrgReports = (me: DirectoryPerson) => authorize(subjectOf(me), 'reports.organization', { organizationId: ORG }, now()).allowed;

  const approvalRecords = (people: readonly DirectoryPerson[]) => {
    const ids = new Set(people.map((p) => p.id));
    return requests
      .filter((r) => ids.has(r.state.requesterId))
      .map((r) => {
        const decided = r.state.status === 'pending' ? undefined : [...r.state.steps].reverse().find((x) => x.decidedAt !== undefined)?.decidedAt;
        return { kind: r.kind, submittedAt: r.submittedAt, status: r.state.status, ...(decided !== undefined ? { decidedAt: decided } : {}) };
      });
  };

  const payrollFor = (people: readonly DirectoryPerson[], start: DateKey) =>
    buildPayrollRegister(
      people.map((p) => {
        const approved = new Map<DateKey, number>();
        for (const r of requests) {
          if (r.state.requesterId === p.id && r.state.status === 'approved' && r.payload.kind === 'overtime') {
            approved.set(r.payload.date, (approved.get(r.payload.date) ?? 0) + r.payload.minutes);
          }
        }
        return {
          userId: p.id,
          name: p.name,
          days: classify(p, start),
          approvedOvertime: approved,
          timesheetStatus: stateOf(p.id, start).status,
          missedPunches: recordsFor(p, start, addDays(start, 6)).filter((x) => x.missedPunch).length,
        };
      }),
      PH_DEFAULT_PAY_POLICY,
    );

  const directoryEntry = (p: DirectoryPerson): DirectoryEntry => {
    const manager = p.managerId !== undefined ? byId.get(p.managerId) : undefined;
    return {
      person: view(p),
      role: p.role,
      ...(p.teamName !== undefined ? { teamName: p.teamName } : {}),
      department: DEPARTMENT_NAMES[p.departmentId] ?? p.departmentId,
      departmentKey: p.departmentId,
      ...(manager !== undefined ? { manager: view(manager) } : {}),
    };
  };

  const deals: Deal[] = [
    ['Contact-center renewal', 'Meridian Telecom', 'proposal', 4_800_000_00, 12],
    ['Billing BPO expansion', 'Harbor Freight PH', 'negotiation', 2_350_000_00, 20],
    ['Night support pilot', 'Luzon Health', 'qualified', 950_000_00, 35],
    ['Collections program', 'Visayas Bank', 'lead', 1_600_000_00, 60],
    ['QA outsourcing', 'Archipelago Air', 'won', 1_200_000_00, -10],
    ['Chat support add-on', 'Meridian Telecom', 'won', 640_000_00, -25],
    ['Multilingual desk', 'Pacific Retail', 'lost', 780_000_00, -18],
    ['Workforce analytics', 'Northstar Logistics', 'proposal', 1_150_000_00, 28],
  ].map(([name, account, stage, amount, days], i) => ({
    id: `deal_${i + 1}`,
    name: String(name),
    account: String(account),
    ownerName: i % 2 === 0 ? 'Rafael Mendoza' : 'Elena Cruz',
    stage: stage as Deal['stage'],
    amountMinor: Number(amount),
    currency: 'PHP',
    closeDate: addDays(seedToday, Number(days)),
  }));
  const readNotifications = new Set<string>();

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
          reports: {
            executive: authorize(s, 'reports.team', { organizationId: ORG, departmentId: me.departmentId }, now()).allowed,
            organization: hasOrgReports(me),
          },
          capabilities: {
            managePeople: authorize(s, 'people.manage', { organizationId: ORG }, now()).allowed,
            offboard: authorize(s, 'people.offboard', { organizationId: ORG }, now()).allowed,
            assignableRoles: assignableRoles(s, now()),
            approveAnything: isOwner(me),
          },
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
        if (!result.value.duplicate) {
          events.set(me.id, [...eventsOf(me.id), result.value.event]);
          audit(me.id, `attendance.${type}`, 'mobile');
        }
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
          const crew = people().filter((p) => p.id !== me.id && p.teamId !== undefined && p.teamId === me.teamId && isScheduled(p, d)).slice(0, 4);
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
        const inChain = currentApprovers(r.state).includes(me.id);
        if (r.state.status === 'pending' && (inChain || isOwner(me))) ensure(DECIDE_PERMISSION[r.kind], requester);
        const override = !inChain && isOwner(me);
        const result = decideApproval(r.state, me.id, decision, { now: now(), override, ...(reason !== undefined ? { reason } : {}) });
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
        audit(me.id, `request.${decision}`, `${r.kind} · ${requester.name}`);
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


    attendanceReport: ({ scope, weeks = 4 }) =>
      respond((): AttendanceReport => {
        const me = actor();
        ensure('attendance.view', me);
        const scoped = scopedPeople(me);
        const orgAllowed = hasOrgReports(me) || grantScope(subjectOf(me), 'attendance.view', now()) === 'organization';
        const availableScopes: ReportScope[] = ['me', ...(scoped.length > 0 ? (['team'] as const) : []), ...(orgAllowed ? (['org'] as const) : [])];
        if (!availableScopes.includes(scope)) throw new ApiError('forbidden', "You don't have access to that report scope.");
        const subjects = scope === 'me' ? [me] : scope === 'team' ? scoped : people();
        const personLevel = subjects.every((p) => p.id === me.id || can('attendance.view', p));

        const { from, to, prevFrom, prevTo } = periodFor(weeks);
        const starts = trendStarts();
        const rangeFrom = [prevFrom, starts[0] ?? prevFrom].sort()[0] ?? prevFrom;
        const all = subjects.flatMap((p) => recordsFor(p, rangeFrom, to));
        const inRange = (a: DateKey, b: DateKey) => all.filter((r) => r.date >= a && r.date <= b);
        const current = inRange(from, to);
        const personById = new Map(subjects.map((p) => [p.id as string, p]));

        const exceptions: AttendanceFlag[] = personLevel
          ? current
              .flatMap((r): AttendanceFlag[] => {
                const who = personById.get(r.userId);
                if (who === undefined) return [];
                const base = { date: r.date, person: view(who) };
                if (r.missedPunch) return [{ ...base, kind: 'missed_punch' }];
                if (r.scheduled && !r.present) return [{ ...base, kind: 'absent' }];
                if (r.lateMinutes > 0) return [{ ...base, kind: 'late', minutes: r.lateMinutes }];
                return [];
              })
              .sort((a, b) => b.date.localeCompare(a.date))
              .slice(0, 40)
          : [];

        return {
          scope,
          from,
          to,
          personLevel,
          metrics: summarizeAttendance(current),
          previous: summarizeAttendance(inRange(prevFrom, prevTo)),
          trend: weeklyTrend(inRange(starts[0] ?? from, to), starts),
          daily: dailyRates(current),
          groups: scope === 'me' ? [] : summarizeBy(current, (r) => groupName(personById.get(r.userId) ?? me)).map((g) => ({ name: g.key, metrics: g.metrics })),
          people:
            personLevel && scope !== 'me'
              ? summarizeBy(current, (r) => r.userId).flatMap((g) => {
                  const who = personById.get(g.key);
                  return who === undefined ? [] : [{ person: view(who), ...(who.teamName !== undefined ? { teamName: who.teamName } : {}), metrics: g.metrics }];
                })
              : [],
          exceptions,
          availableScopes,
        };
      }),

    executiveReport: ({ weeks = 4 } = {}) =>
      respond((): ExecutiveReport => {
        const me = actor();
        if (!authorize(subjectOf(me), 'reports.team', { organizationId: ORG, departmentId: me.departmentId }, now()).allowed) {
          throw new ApiError('forbidden', "You don't have access to executive reports.");
        }
        const org = hasOrgReports(me);
        const subjects = org ? people() : [me, ...scopedPeople(me)];
        const { from, to, prevFrom, prevTo } = periodFor(weeks);
        const starts = trendStarts();
        const rangeFrom = [prevFrom, starts[0] ?? prevFrom].sort()[0] ?? prevFrom;
        const all = subjects.flatMap((p) => recordsFor(p, rangeFrom, to));
        const inRange = (a: DateKey, b: DateKey) => all.filter((r) => r.date >= a && r.date <= b);
        const current = inRange(from, to);
        const previous = inRange(prevFrom, prevTo);
        const byUser = new Map(subjects.map((p) => [p.id as string, p]));
        const groupOf = (r: DayRecord) => groupName(byUser.get(r.userId) ?? me);

        const laborMix = summarizePayLines(subjects.flatMap((p) => classifySessions(sessionsIn(p, from, to), payCtx(p))));
        const teams = summarizeBy(current, groupOf).map((g) => ({
          name: g.key,
          headcount: subjects.filter((p) => groupName(p) === g.key).length,
          metrics: g.metrics,
        }));
        const sla = approvalSla(approvalRecords(subjects), now());
        const balances = subjects.flatMap((p) => balancesOf(p));
        const register = payrollFor(subjects, lastWeek);
        const cur = summarizeAttendance(current);
        const prev = summarizeAttendance(previous);

        const risks: ExecutiveReport['risks'][number][] = [
          ...teams.filter((t) => t.metrics.attendanceRate < 0.95).map((t) => ({ key: 'low_attendance' as const, subject: t.name, value: t.metrics.attendanceRate })),
          ...teams.filter((t) => t.metrics.overtimeShare > 0.06).map((t) => ({ key: 'high_overtime' as const, subject: t.name, value: t.metrics.overtimeShare })),
          ...(cur.punctualityRate < prev.punctualityRate - 0.02 ? [{ key: 'late_trend' as const, subject: '', value: cur.punctualityRate - prev.punctualityRate }] : []),
          ...(sla.overdue > 0 ? [{ key: 'approvals_overdue' as const, subject: '', value: sla.overdue }] : []),
          ...(cur.missedPunches > 0 ? [{ key: 'missed_punches' as const, subject: '', value: cur.missedPunches }] : []),
        ];

        return {
          from,
          to,
          scopeLabel: org ? 'organization' : me.role === 'supervisor' ? 'team' : 'department',
          current: cur,
          previous: prev,
          trend: weeklyTrend(inRange(starts[0] ?? from, to), starts),
          laborMix,
          weightedMinutes: weightedMinutes(laborMix),
          teams,
          approvals: sla,
          leave: {
            entitled: balances.reduce((n, b) => n + b.entitled, 0),
            available: balances.reduce((n, b) => n + b.available, 0),
            takenDays: current.filter((r) => r.onLeave).length,
          },
          payroll: { periodStart: lastWeek, ready: register.ready, blockers: register.blockers, unapprovedOvertimeMinutes: register.totals.unapprovedOvertimeMinutes },
          risks,
        };
      }),

    directory: () =>
      respond(() => {
        const me = actor();
        if (!authorize(subjectOf(me), 'people.directory', { organizationId: ORG }, now()).allowed) throw new ApiError('forbidden', "You don't have access to the directory.");
        return people().map(directoryEntry);
      }),


    createEmployee: (input) =>
      respond(() => {
        const me = actor();
        const s = subjectOf(me);
        if (!authorize(s, 'people.manage', { organizationId: ORG }, now()).allowed) throw new ApiError('forbidden', "You can't add employees.");
        const assign = canAssignRole(s, input.role, { now: now() });
        if (!assign.allowed) throw new ApiError(assign.reason, 'You can only assign roles whose permissions you hold.');
        const name = input.name.trim();
        const title = input.title.trim();
        if (name.length < 2 || title.length < 2) throw new ApiError('invalid', 'Name and title are required.');
        const manager = person(input.managerId);
        if (offboarded.has(manager.id)) throw new ApiError('invalid', 'Choose an active manager.');
        const departmentId = (Object.keys(DEPARTMENT_NAMES).find((k) => DEPARTMENT_NAMES[k] === input.department || k === input.department) ?? manager.departmentId) as DirectoryPerson['departmentId'];
        const team = input.teamName !== undefined ? people().find((p) => p.teamName === input.teamName) : undefined;
        const p = mk(`u_${nextId('emp')}`, name, title, input.role, Math.abs(hash(name)) % 360, {
          departmentId,
          managerId: manager.id,
          ...(team?.teamId !== undefined ? { teamId: team.teamId, teamName: team.teamName ?? '' } : {}),
        });
        replacePerson(p);
        audit(me.id, 'member.added', `${name} · ${input.role}`);
        return directoryEntry(p);
      }),

    updateEmployee: (id, patch) =>
      respond(() => {
        const me = actor();
        const s = subjectOf(me);
        const target = person(id);
        if (offboarded.has(id)) throw new ApiError('already_inactive', 'This person has been offboarded.');
        if (!authorize(s, 'people.manage', resourceOf(target), now()).allowed) throw new ApiError('forbidden', "You can't edit this employee.");
        if (patch.role !== undefined && patch.role !== target.role) {
          const assign = canAssignRole(s, patch.role, { targetUserId: id, now: now() });
          if (!assign.allowed) throw new ApiError(assign.reason, 'You can only assign roles whose permissions you hold.');
          if (target.role === 'owner' && people().filter((p) => p.role === 'owner').length <= 1) throw new ApiError('last_owner', 'An organization must keep at least one owner.');
        }
        let next: DirectoryPerson = { ...target, ...(patch.title !== undefined && patch.title.trim().length > 1 ? { title: patch.title.trim() } : {}), ...(patch.role !== undefined ? { role: patch.role } : {}) };
        if (patch.managerId !== undefined && patch.managerId !== target.managerId) {
          if (patch.managerId === id) throw new ApiError('invalid', 'Someone cannot report to themselves.');
          next = { ...next, managerId: patch.managerId };
          const previous = target;
          replacePerson(next);
          const chain = managerChain(id, orgMembers);
          if (!chain.ok) {
            replacePerson(previous);
            throw new ApiError(chain.error.code, 'That change would create a reporting loop.');
          }
        }
        replacePerson(next);
        audit(me.id, 'member.updated', `${target.name}${patch.role !== undefined ? ` · ${patch.role}` : ''}`);
        return directoryEntry(next);
      }),

    offboardEmployee: (id) =>
      respond(() => {
        const me = actor();
        const target = person(id);
        if (!authorize(subjectOf(me), 'people.offboard', resourceOf(target), now()).allowed) throw new ApiError('forbidden', "You can't offboard this employee.");
        const plan = planOffboarding(
          me.id,
          id,
          allPeople.map((p) => ({ id: p.id, roles: [p.role], active: !offboarded.has(p.id), ...(p.managerId !== undefined ? { managerId: p.managerId } : {}) })),
        );
        if (!plan.ok) throw new ApiError(plan.error.code, plan.error.message);
        for (const r of plan.value.reassignments) {
          const report = person(r.userId);
          const { managerId: _old, ...rest } = report;
          replacePerson(r.newManagerId !== undefined ? { ...rest, managerId: r.newManagerId } : rest);
        }
        offboarded.add(id);
        rebuildOrg();
        audit(me.id, 'member.offboarded', target.name);
      }),

    profile: (userId) =>
      respond((): PersonProfile => {
        const me = actor();
        if (!authorize(subjectOf(me), 'people.directory', { organizationId: ORG }, now()).allowed) throw new ApiError('forbidden', "You don't have access to the directory.");
        const p = person(userId);
        const sensitive = p.id === me.id || authorize(subjectOf(me), 'people.view', { ...resourceOf(p), sensitive: true }, now()).allowed;
        const h = Math.abs(hash(p.id));
        const fmt = (hm: readonly [number, number]) => `${String(hm[0]).padStart(2, '0')}:${String(hm[1]).padStart(2, '0')}`;
        return {
          ...directoryEntry(p),
          chain: chainOf(p).map((id) => view(person(id))),
          directReports: people().filter((x) => x.managerId === p.id).map(view),
          location: p.location,
          shift: `${fmt(p.shift.start)}–${fmt(p.shift.end)}`,
          restDays: p.restDays,
          ...(sensitive
            ? {
                sensitive: {
                  employeeId: `NF-${String(1000 + (h % 9000))}`,
                  hireDate: addDays('2021-01-04', h % 1500),
                  payGrade: p.role === 'staff' ? 'P2' : p.role === 'supervisor' ? 'M1' : p.role === 'manager' ? 'M2' : 'E1',
                  emergencyContact: 'On file',
                },
              }
            : {}),
        };
      }),

    payroll: (periodStart) =>
      respond((): PayrollView => {
        const me = actor();
        if (!authorize(subjectOf(me), 'payroll.view', { organizationId: ORG }, now()).allowed) throw new ApiError('forbidden', "You don't have access to payroll.");
        const start = periodStart ?? lastWeek;
        const register = payrollFor(people(), start);
        const locked = lockedPeriods.has(start);
        const canPrepare = authorize(subjectOf(me), 'payroll.prepare', { organizationId: ORG }, now()).allowed;
        return { ...register, periodStart: start, periodEnd: addDays(start, 6), locked, canLock: canPrepare && register.ready && !locked };
      }),

    lockPayroll: (periodStart) =>
      respond(() => {
        const me = actor();
        if (!authorize(subjectOf(me), 'payroll.prepare', { organizationId: ORG }, now()).allowed) throw new ApiError('forbidden', "You can't lock payroll periods.");
        if (lockedPeriods.has(periodStart)) throw new ApiError('closed', 'This period is already locked.');
        const register = payrollFor(people(), periodStart);
        if (!register.ready) throw new ApiError('not_ready', `${register.blockers} employee(s) still block this period.`);
        const updates: [UserId, SheetState][] = [];
        for (const p of people()) {
          if (stateOf(p.id, periodStart).status !== 'approved') continue;
          const t = transitionTimesheet(sheetFor(p, periodStart), 'lock', subjectOf(me), { now: now() });
          if (!t.ok) throw new ApiError(t.error.code, t.error.message);
          updates.push([p.id, { status: t.value.status, history: [...t.value.history], version: t.value.version }]);
        }
        for (const [id, st] of updates) sheetState.set(sheetKey(id, periodStart), st);
        lockedPeriods.add(periodStart);
        audit(me.id, 'payroll.locked', periodStart);
      }),

    admin: () =>
      respond((): AdminOverview => {
        const me = actor();
        const s = subjectOf(me);
        if (!authorize(s, 'admin.roles', { organizationId: ORG }, now()).allowed && !authorize(s, 'admin.audit', { organizationId: ORG }, now()).allowed) {
          throw new ApiError('forbidden', "You don't have access to administration.");
        }
        return {
          members: people().map(directoryEntry),
          audit: [...auditLog]
            .sort((a, b) => b.at.localeCompare(a.at))
            .slice(0, 150)
            .map((e): AuditEntry => ({ id: e.id, at: e.at, actor: view(person(e.actorId)), action: e.action, detail: e.detail })),
          holidays: Object.entries(DEMO_HOLIDAYS).map(([date, h]) => ({ date: date as DateKey, kind: h.kind, name: h.name })),
          payPolicy: PH_DEFAULT_PAY_POLICY,
        };
      }),

    deals: () =>
      respond(() => {
        const me = actor();
        if (!authorize(subjectOf(me), 'crm.view', { organizationId: ORG }, now()).allowed) throw new ApiError('forbidden', "You don't have access to CRM.");
        return deals;
      }),

    moveDeal: (id, stage, reason) =>
      respond(() => {
        const me = actor();
        if (!authorize(subjectOf(me), 'crm.manage', { organizationId: ORG }, now()).allowed) throw new ApiError('forbidden', 'You can view the pipeline but not change it.');
        const i = deals.findIndex((d) => d.id === id);
        const deal = deals[i];
        if (deal === undefined) throw new ApiError('not_found', 'That deal no longer exists.');
        const r = moveDealRule(deal, stage, reason);
        if (!r.ok) throw new ApiError(r.error.code, r.error.message);
        deals[i] = r.value;
        audit(me.id, 'crm.deal_moved', `${deal.name} → ${stage}`);
        return r.value;
      }),

    notifications: () =>
      respond(() => {
        const me = actor();
        const out: NotificationItem[] = [];
        const mine = requests.filter((r) => currentApprovers(r.state).includes(me.id) && can(DECIDE_PERMISSION[r.kind], person(r.state.requesterId)));
        if (mine.length > 0) {
          const newest = mine.map((r) => r.submittedAt).sort().at(-1) ?? now().toISOString();
          out.push({ id: `appr_${mine.length}`, kind: 'approval_needed', at: newest, read: false, params: { count: String(mine.length) }, href: '/more/approvals' });
        }
        const cutoff = now().getTime() - 14 * 86_400_000;
        for (const r of requests) {
          if (r.state.requesterId !== me.id || r.state.status === 'pending') continue;
          const decided = [...r.state.steps].reverse().find((x) => x.decidedAt !== undefined);
          if (decided?.decidedAt === undefined || Date.parse(decided.decidedAt) < cutoff) continue;
          out.push({ id: `dec_${r.id}`, kind: 'request_decided', at: decided.decidedAt, read: false, params: { kind: r.kind, status: r.state.status, by: person(decided.approverId).name }, href: '/more/timeoff' });
        }
        const sheet = stateOf(me.id, lastWeek);
        if ((sheet.status === 'draft' || sheet.status === 'returned') && classify(me, lastWeek).length > 0) {
          out.push({ id: `ts_${lastWeek}`, kind: 'timesheet_due', at: at(weekStart(today()), 8, 0), read: false, params: { period: lastWeek }, href: '/more/timesheets' });
        }
        const missed = replayOf(me.id).exceptions.filter((x) => x.kind === 'missed_clock_out');
        for (const x of missed) out.push({ id: `miss_${x.at}`, kind: 'missed_punch', at: x.at, read: false, params: { at: x.at }, href: '/clock' });
        if (authorize(subjectOf(me), 'payroll.prepare', { organizationId: ORG }, now()).allowed) {
          const reg = payrollFor(people(), lastWeek);
          if (!lockedPeriods.has(lastWeek)) out.push({ id: `pay_${lastWeek}_${reg.blockers}`, kind: 'payroll_ready', at: at(weekStart(today()), 7, 0), read: false, params: { blockers: String(reg.blockers), period: lastWeek }, href: '/more/payroll' });
        }
        return out.map((n) => ({ ...n, read: readNotifications.has(n.id) })).sort((a, b) => b.at.localeCompare(a.at));
      }),

    markNotificationsRead: (ids) =>
      respond(() => {
        for (const id of ids) readNotifications.add(id);
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
        const statuses = scoped.length > 0 ? scoped.map((m) => m.status) : people().filter((p) => p.id !== me.id).map((p) => memberStatus(p).status);
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
