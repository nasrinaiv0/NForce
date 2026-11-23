import { DEAL_STAGES, ROLE_TEMPLATES, weightedMinutes, type AttendanceMetrics, type Deal, type FieldDef, type FieldOption, type PayrollRow, type Task } from '@nforce/core';

import type { I18n } from '@/i18n';
import type {
  ApprovalItem,
  AttendanceFlag,
  AttendanceReport,
  AuditEntry,
  DirectReport,
  DirectoryEntry,
  MyRequest,
  NotificationItem,
  RosterCell,
  RosterRow,
  Shift,
  TeamMember,
  TimesheetDay,
} from './types';

/**
 * The columns each list can be sorted and filtered by. Every list in the app
 * gets its fields from here, so labels, value readers and options stay
 * consistent (and are tested against real data).
 */

const opts = (values: readonly string[], label: (v: string) => string): FieldOption[] => values.map((value) => ({ value, label: label(value) }));
const roleOptions = (i18n: I18n) => opts(ROLE_TEMPLATES, (r) => i18n.t(`role.${r}` as never));

const REQUEST_KINDS = ['leave', 'day_off', 'overtime', 'timesheet', 'correction'] as const;
const REQUEST_STATUSES = ['pending', 'approved', 'returned', 'cancelled'] as const;
const MEMBER_STATUSES = ['missed_punch', 'late', 'absent', 'working', 'on_break', 'not_started', 'done', 'off'] as const;
const PRIORITIES = ['urgent', 'high', 'normal', 'low'] as const;
const TASK_STATUSES = ['todo', 'in_progress', 'blocked', 'done'] as const;
const DAY_TYPES = ['ordinary', 'rest_day', 'special', 'special_rest_day', 'regular_holiday', 'regular_holiday_rest_day'] as const;
const PAYROLL_FLAGS = ['timesheet_not_approved', 'unapproved_overtime', 'missed_punch'] as const;
const NOTIFICATION_KINDS = ['approval_needed', 'request_decided', 'timesheet_due', 'missed_punch', 'payroll_ready'] as const;

type Payload = ApprovalItem['payload'];
const startOf = (p: Payload) => ('start' in p ? p.start : 'date' in p ? p.date : p.periodStart);
const daysOf = (p: Payload) => (p.kind === 'leave' || p.kind === 'day_off' ? p.days : undefined);
const minutesOf = (p: Payload) => (p.kind === 'overtime' || p.kind === 'timesheet' ? p.minutes : undefined);

function requestCommon<T extends { kind: ApprovalItem['kind']; status: ApprovalItem['status']; submittedAt: string; payload: Payload }>(i18n: I18n): FieldDef<T>[] {
  return [
    { key: 'kind', label: i18n.t('field.kind'), kind: 'choice', get: (r) => r.kind, options: opts(REQUEST_KINDS, (k) => i18n.t(`approvals.kind.${k}` as never)) },
    { key: 'status', label: i18n.t('field.status'), kind: 'choice', get: (r) => r.status, options: opts(REQUEST_STATUSES, (s) => i18n.t(`approvals.status.${s}` as never)) },
    { key: 'submitted', label: i18n.t('field.submitted'), kind: 'date', get: (r) => r.submittedAt },
    { key: 'starts', label: i18n.t('field.starts'), kind: 'date', get: (r) => startOf(r.payload) },
    { key: 'days', label: i18n.t('field.days'), kind: 'number', get: (r) => daysOf(r.payload) },
    { key: 'hours', label: i18n.t('field.hours'), kind: 'duration', get: (r) => minutesOf(r.payload) },
  ];
}

export function approvalFields(i18n: I18n): FieldDef<ApprovalItem>[] {
  return [
    { key: 'requester', label: i18n.t('field.requester'), kind: 'text', get: (a) => a.requester.name },
    { key: 'team', label: i18n.t('field.team'), kind: 'text', get: (a) => a.teamName },
    ...requestCommon<ApprovalItem>(i18n),
    {
      key: 'stage',
      label: i18n.t('field.stage'),
      kind: 'choice',
      get: (a) => a.steps.find((s) => s.status === 'pending')?.level ?? 'closed',
      options: [
        { value: 'supervisor', label: i18n.t('approvals.level.supervisor') },
        { value: 'manager', label: i18n.t('approvals.level.manager') },
        { value: 'closed', label: i18n.t('opt.stage.closed') },
      ],
    },
    { key: 'mine', label: i18n.t('field.waitingOnMe'), kind: 'boolean', get: (a) => a.canDecide },
  ];
}

export const myRequestFields = (i18n: I18n): FieldDef<MyRequest>[] => requestCommon<MyRequest>(i18n);

export function teamMemberFields(i18n: I18n): FieldDef<TeamMember>[] {
  return [
    { key: 'name', label: i18n.t('field.name'), kind: 'text', get: (m) => m.person.name },
    { key: 'title', label: i18n.t('field.title'), kind: 'text', get: (m) => m.person.title },
    { key: 'team', label: i18n.t('field.team'), kind: 'text', get: (m) => m.teamName },
    { key: 'role', label: i18n.t('field.role'), kind: 'choice', get: (m) => m.role, options: roleOptions(i18n) },
    { key: 'manager', label: i18n.t('field.manager'), kind: 'text', get: (m) => m.managerName },
    { key: 'status', label: i18n.t('field.status'), kind: 'choice', get: (m) => m.status, options: opts(MEMBER_STATUSES, (s) => i18n.t(`team.status.${s}` as never)) },
    { key: 'today', label: i18n.t('field.today'), kind: 'duration', get: (m) => m.todayMinutes },
    { key: 'week', label: i18n.t('field.week'), kind: 'duration', get: (m) => m.weekMinutes },
    { key: 'overtime', label: i18n.t('field.overtime'), kind: 'duration', get: (m) => m.weekOvertimeMinutes },
    { key: 'night', label: i18n.t('field.night'), kind: 'duration', get: (m) => m.weekNightMinutes },
    { key: 'late', label: i18n.t('field.late'), kind: 'duration', get: (m) => m.lateByMinutes ?? 0 },
    { key: 'pending', label: i18n.t('field.pending'), kind: 'number', get: (m) => m.pendingRequests },
  ];
}

export function directoryFields(i18n: I18n): FieldDef<DirectoryEntry>[] {
  return [
    { key: 'name', label: i18n.t('field.name'), kind: 'text', get: (p) => p.person.name },
    { key: 'title', label: i18n.t('field.title'), kind: 'text', get: (p) => p.person.title },
    { key: 'department', label: i18n.t('field.department'), kind: 'text', get: (p) => p.department },
    { key: 'team', label: i18n.t('field.team'), kind: 'text', get: (p) => p.teamName },
    { key: 'role', label: i18n.t('field.role'), kind: 'choice', get: (p) => p.role, options: roleOptions(i18n) },
    { key: 'manager', label: i18n.t('field.manager'), kind: 'text', get: (p) => p.manager?.name },
  ];
}

export function directReportFields(i18n: I18n): FieldDef<DirectReport>[] {
  return [
    { key: 'name', label: i18n.t('field.name'), kind: 'text', get: (r) => r.person.name },
    { key: 'title', label: i18n.t('field.title'), kind: 'text', get: (r) => r.person.title },
    { key: 'team', label: i18n.t('field.team'), kind: 'text', get: (r) => r.teamName },
    { key: 'role', label: i18n.t('field.role'), kind: 'choice', get: (r) => r.role, options: roleOptions(i18n) },
    { key: 'reports', label: i18n.t('field.reports'), kind: 'number', get: (r) => r.reports },
  ];
}

export function taskFields(i18n: I18n): FieldDef<Task>[] {
  return [
    { key: 'title', label: i18n.t('field.title.task'), kind: 'text', get: (x) => x.title },
    { key: 'priority', label: i18n.t('field.priority'), kind: 'choice', get: (x) => x.priority, options: opts(PRIORITIES, (p) => i18n.t(`work.priority.${p}` as never)) },
    { key: 'status', label: i18n.t('field.status'), kind: 'choice', get: (x) => x.status, options: opts(TASK_STATUSES, (s) => i18n.t(`opt.task.${s}` as never)) },
    { key: 'due', label: i18n.t('field.due'), kind: 'date', get: (x) => x.due },
    { key: 'linked', label: i18n.t('field.linked'), kind: 'boolean', get: (x) => x.link !== undefined, sortable: false },
  ];
}

export function dealFields(i18n: I18n): FieldDef<Deal>[] {
  return [
    { key: 'name', label: i18n.t('field.name'), kind: 'text', get: (d) => d.name },
    { key: 'account', label: i18n.t('field.account'), kind: 'text', get: (d) => d.account },
    { key: 'owner', label: i18n.t('field.owner'), kind: 'text', get: (d) => d.ownerName },
    { key: 'stage', label: i18n.t('field.stage.deal'), kind: 'choice', get: (d) => d.stage, options: opts(DEAL_STAGES, (s) => i18n.t(`crm.stage.${s}` as never)) },
    { key: 'amount', label: i18n.t('field.amount'), kind: 'number', get: (d) => d.amountMinor / 100 },
    { key: 'close', label: i18n.t('field.closeDate'), kind: 'date', get: (d) => d.closeDate },
  ];
}

export function notificationFields(i18n: I18n): FieldDef<NotificationItem>[] {
  return [
    { key: 'kind', label: i18n.t('field.kind'), kind: 'choice', get: (n) => n.kind, options: opts(NOTIFICATION_KINDS, (k) => i18n.t(`opt.notify.${k}` as never)) },
    { key: 'date', label: i18n.t('field.date'), kind: 'date', get: (n) => n.at },
    { key: 'unread', label: i18n.t('field.unread'), kind: 'boolean', get: (n) => !n.read },
  ];
}

export function timesheetDayFields(i18n: I18n): FieldDef<TimesheetDay>[] {
  return [
    { key: 'date', label: i18n.t('field.date'), kind: 'date', get: (d) => d.date },
    { key: 'dayType', label: i18n.t('field.dayType'), kind: 'choice', get: (d) => d.dayType, options: opts(DAY_TYPES, (k) => i18n.t(`pay.day.${k}` as never)) },
    { key: 'worked', label: i18n.t('field.worked'), kind: 'duration', get: (d) => d.workedMinutes },
    { key: 'regular', label: i18n.t('field.regular'), kind: 'duration', get: (d) => d.regularMinutes },
    { key: 'overtime', label: i18n.t('field.overtime'), kind: 'duration', get: (d) => d.overtimeMinutes },
    { key: 'otApproved', label: i18n.t('field.otApproved'), kind: 'duration', get: (d) => d.overtime.approvedMinutes },
    { key: 'night', label: i18n.t('field.night'), kind: 'duration', get: (d) => d.nightMinutes },
    { key: 'break', label: i18n.t('field.break'), kind: 'duration', get: (d) => d.breakMinutes },
    { key: 'paid', label: i18n.t('field.paid'), kind: 'duration', get: (d) => weightedMinutes(d.lines) },
    { key: 'unapproved', label: i18n.t('field.unapprovedOt'), kind: 'boolean', get: (d) => d.overtime.unapprovedMinutes > 0 },
    { key: 'holiday', label: i18n.t('field.holiday'), kind: 'text', get: (d) => d.holidayName },
  ];
}

const CELL_KINDS = ['shift', 'off', 'leave', 'holiday'] as const;
const cellOptions = (i18n: I18n) => opts(CELL_KINDS, (k) => i18n.t(`opt.cell.${k}` as never));

export function rosterFields(i18n: I18n): FieldDef<RosterRow>[] {
  return [
    { key: 'name', label: i18n.t('field.name'), kind: 'text', get: (r) => r.person.name },
    { key: 'team', label: i18n.t('field.team'), kind: 'text', get: (r) => r.teamName },
    { key: 'role', label: i18n.t('field.role'), kind: 'choice', get: (r) => r.role, options: roleOptions(i18n) },
    { key: 'hours', label: i18n.t('field.hours'), kind: 'duration', get: (r) => r.minutes },
    { key: 'shifts', label: i18n.t('field.shifts'), kind: 'number', get: (r) => r.days.filter((d) => d.cell.kind === 'shift').length },
    { key: 'leave', label: i18n.t('field.leaveDays'), kind: 'number', get: (r) => r.days.filter((d) => d.cell.kind === 'leave').length },
    { key: 'night', label: i18n.t('field.nightShift'), kind: 'boolean', get: (r) => r.days.some((d) => d.cell.kind === 'shift' && d.cell.night) },
    { key: 'has', label: i18n.t('field.scheduleHas'), kind: 'choice', get: (r) => [...new Set(r.days.map((d) => d.cell.kind))], options: cellOptions(i18n), sortable: false },
  ];
}

export interface ScheduleDayRow {
  readonly date: string;
  readonly cell: RosterCell;
  readonly shift: Shift | undefined;
}

export function scheduleDayFields<T extends ScheduleDayRow>(i18n: I18n): FieldDef<T>[] {
  return [
    { key: 'date', label: i18n.t('field.date'), kind: 'date', get: (r) => r.date },
    { key: 'kind', label: i18n.t('field.schedule'), kind: 'choice', get: (r) => r.cell.kind, options: cellOptions(i18n) },
    { key: 'hours', label: i18n.t('field.hours'), kind: 'duration', get: (r) => (r.cell.kind === 'shift' ? r.cell.minutes : 0) },
    { key: 'night', label: i18n.t('field.nightShift'), kind: 'boolean', get: (r) => r.cell.kind === 'shift' && r.cell.night },
    { key: 'location', label: i18n.t('field.location'), kind: 'text', get: (r) => r.shift?.location },
  ];
}

export function payrollFields(i18n: I18n): FieldDef<PayrollRow>[] {
  return [
    { key: 'name', label: i18n.t('field.name'), kind: 'text', get: (r) => r.name },
    { key: 'payable', label: i18n.t('field.payable'), kind: 'duration', get: (r) => r.payableMinutes },
    { key: 'paid', label: i18n.t('field.paid'), kind: 'duration', get: (r) => r.weightedMinutes },
    { key: 'overtime', label: i18n.t('field.overtime'), kind: 'duration', get: (r) => r.lines.filter((l) => l.overtime).reduce((n, l) => n + l.minutes, 0) },
    { key: 'night', label: i18n.t('field.night'), kind: 'duration', get: (r) => r.lines.filter((l) => l.night).reduce((n, l) => n + l.minutes, 0) },
    { key: 'unapproved', label: i18n.t('field.unapprovedOt'), kind: 'duration', get: (r) => r.unapprovedOvertimeMinutes },
    { key: 'flags', label: i18n.t('field.flags'), kind: 'choice', get: (r) => r.flags, options: opts(PAYROLL_FLAGS, (f) => i18n.t(`payroll.flag.${f}` as never)), sortable: false },
    { key: 'blocked', label: i18n.t('field.blocked'), kind: 'boolean', get: (r) => r.flags.length > 0 },
  ];
}

/** Rate/count metrics shared by people, team and group rows. */
function metricFields<T>(i18n: I18n, m: (row: T) => AttendanceMetrics): FieldDef<T>[] {
  return [
    { key: 'attendance', label: i18n.t('field.attendance'), kind: 'percent', get: (r) => m(r).attendanceRate },
    { key: 'punctuality', label: i18n.t('field.punctuality'), kind: 'percent', get: (r) => m(r).punctualityRate },
    { key: 'lateDays', label: i18n.t('field.lateDays'), kind: 'number', get: (r) => m(r).lateDays },
    { key: 'absences', label: i18n.t('field.absences'), kind: 'number', get: (r) => m(r).absentDays },
    { key: 'worked', label: i18n.t('field.worked'), kind: 'duration', get: (r) => m(r).workedMinutes },
    { key: 'overtime', label: i18n.t('field.overtime'), kind: 'duration', get: (r) => m(r).overtimeMinutes },
    { key: 'otShare', label: i18n.t('field.otShare'), kind: 'percent', get: (r) => m(r).overtimeShare },
    { key: 'night', label: i18n.t('field.night'), kind: 'duration', get: (r) => m(r).nightMinutes },
    { key: 'missed', label: i18n.t('field.missedPunches'), kind: 'number', get: (r) => m(r).missedPunches },
  ];
}

export function attendancePeopleFields(i18n: I18n): FieldDef<AttendanceReport['people'][number]>[] {
  return [
    { key: 'name', label: i18n.t('field.name'), kind: 'text', get: (p) => p.person.name },
    { key: 'team', label: i18n.t('field.team'), kind: 'text', get: (p) => p.teamName },
    ...metricFields<AttendanceReport['people'][number]>(i18n, (p) => p.metrics),
  ];
}

export function groupFields<T extends { name: string; metrics: AttendanceMetrics; headcount?: number }>(i18n: I18n): FieldDef<T>[] {
  return [
    { key: 'name', label: i18n.t('field.name.group'), kind: 'text', get: (g) => g.name },
    { key: 'headcount', label: i18n.t('field.headcount'), kind: 'number', get: (g) => g.headcount ?? g.metrics.headcount },
    ...metricFields<T>(i18n, (g) => g.metrics),
  ];
}

export function exceptionFields(i18n: I18n): FieldDef<AttendanceFlag>[] {
  return [
    { key: 'name', label: i18n.t('field.name'), kind: 'text', get: (e) => e.person.name },
    { key: 'kind', label: i18n.t('field.kind'), kind: 'choice', get: (e) => e.kind, options: opts(['late', 'absent', 'missed_punch'], (k) => i18n.t(`reports.flag.${k}` as never)) },
    { key: 'date', label: i18n.t('field.date'), kind: 'date', get: (e) => e.date },
    { key: 'minutes', label: i18n.t('field.late'), kind: 'duration', get: (e) => e.minutes ?? 0 },
  ];
}

export function auditFields(i18n: I18n): FieldDef<AuditEntry>[] {
  return [
    { key: 'date', label: i18n.t('field.date'), kind: 'date', get: (e) => e.at },
    { key: 'actor', label: i18n.t('field.actor'), kind: 'text', get: (e) => e.actor.name },
    { key: 'action', label: i18n.t('field.action'), kind: 'text', get: (e) => e.action },
    { key: 'detail', label: i18n.t('field.detail'), kind: 'text', get: (e) => e.detail },
  ];
}

export function holidayFields<T extends { date: string; kind: 'regular' | 'special'; name: string }>(i18n: I18n): FieldDef<T>[] {
  return [
    { key: 'date', label: i18n.t('field.date'), kind: 'date', get: (h) => h.date },
    { key: 'name', label: i18n.t('field.name.holiday'), kind: 'text', get: (h) => h.name },
    { key: 'kind', label: i18n.t('field.kind'), kind: 'choice', get: (h) => h.kind, options: opts(['regular', 'special'], (k) => i18n.t(`opt.holiday.${k}` as never)) },
  ];
}
