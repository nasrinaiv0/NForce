import {
  OrganizationId,
  ROLE_TEMPLATES,
  UserId,
  addDays,
  type ApprovalStatus,
  type ApprovalStep,
  type AttendanceEvent,
  type AttendanceEventType,
  type AttendanceSource,
  type DateKey,
  type Deal,
  type DealStage,
  type DepartmentId,
  type HolidayKind,
  type LeavePolicy,
  type RoleTemplate,
  type Task,
  type TaskPriority,
  type TaskStatus,
  type TeamId,
  type TimesheetStatus,
} from '@nforce/core';
import type { PostgrestError, SupabaseClient } from '@supabase/supabase-js';

import type { Dataset, DirectoryPerson, RequestRecord } from './mockApi';
import { ApiError, type LeaveBalance, type RequestKind, type RequestPayload } from './types';

/**
 * Live data: rows read from Supabase (row-level security already applied, so
 * each person only receives what they may see) mapped into the snapshot the
 * backend computes every screen from.
 */

// ------------------------------------------------------------------ rows

export interface DirectoryRow {
  user_id: string;
  membership_id: string;
  display_name: string;
  job_title: string;
  location: string;
  status: 'active' | 'invited' | 'suspended' | 'ended';
  department_id: string | null;
  department_name: string | null;
  team_id: string | null;
  team_name: string | null;
  reports_to_user: string | null;
  role_key: string | null;
  shift_start: string | null;
  shift_end: string | null;
  rest_days: number[] | null;
}
export interface EventRow { id: string; user_id: string; type: AttendanceEventType; occurred_at: string; source: AttendanceSource; idempotency_key: string; note: string | null }
export interface RequestRow { id: string; requester_id: string; kind: RequestKind; payload: RequestPayload; status: ApprovalStatus; created_at: string }
export interface StepRow { request_id: string; position: number; level: ApprovalStep['level']; approver_id: string; status: ApprovalStep['status']; decided_by: string | null; decided_at: string | null; reason: string | null }
export interface SheetRow { user_id: string; period_start: string; status: TimesheetStatus; version: number }
export interface BalanceRow { user_id: string; leave_type: string; available_days: number | string; entitled_days: number | string | null }
export interface LeaveTypeRow { key: string; name: string; allow_half_days: boolean; min_notice_days: number; max_consecutive_days: number }
export interface HolidayRow { date: string; kind: HolidayKind; name: string }
export interface WorkItemRow { id: string; assignee_id: string; created_by: string; title: string; status: TaskStatus; priority: TaskPriority; due: string | null }
export interface DealRow { id: string; account_id: string; name: string; stage: DealStage; amount_minor: number | string; currency: string; owner_id: string | null; close_date: string | null }
export interface AuditRow { id: number | string; actor_id: string | null; action: string; entity: string; data: Record<string, unknown> | null; occurred_at: string }

export interface LiveRows {
  directory: readonly DirectoryRow[];
  events: readonly EventRow[];
  requests: readonly RequestRow[];
  steps: readonly StepRow[];
  sheets: readonly SheetRow[];
  balances: readonly BalanceRow[];
  leaveTypes: readonly LeaveTypeRow[];
  holidays: readonly HolidayRow[];
  workItems: readonly WorkItemRow[];
  payrollPeriods: readonly { period_start: string }[];
  deals: readonly DealRow[];
  accounts: readonly { id: string; name: string }[];
  audit: readonly AuditRow[];
}

export interface Workspace {
  readonly organizationId: string;
  readonly name: string;
  readonly timeZone: string;
  readonly membershipId: string;
  readonly role: RoleTemplate;
}

/** The snapshot plus the ids the write functions need. */
export interface LiveData {
  readonly dataset: Dataset;
  /** user id → membership id (role, reporting line and offboarding RPCs take membership ids). */
  readonly membershipOf: ReadonlyMap<string, string>;
  /** department name → id. */
  readonly departmentIdOf: ReadonlyMap<string, string>;
}

// ------------------------------------------------------------------ mapping

const LEAVE_HUES = [225, 150, 285, 25, 190, 330];
const hueOf = (id: string) => Math.abs([...id].reduce((h, c) => (Math.imul(h, 31) + c.charCodeAt(0)) | 0, 7)) % 360;
const initialsOf = (name: string) =>
  name
    .split(/\s+/)
    .filter(Boolean)
    .map((p) => p[0] ?? '')
    .join('')
    .slice(0, 2)
    .toUpperCase() || '?';
const hm = (time: string): [number, number] => {
  const [h = '0', m = '0'] = time.split(':');
  return [Number(h), Number(m)];
};
const num = (v: number | string | null | undefined) => (v === null || v === undefined ? 0 : Number(v));
const isRole = (r: string | null): r is RoleTemplate => r !== null && (ROLE_TEMPLATES as readonly string[]).includes(r);
const UNASSIGNED = 'unassigned';

function auditDetail(row: AuditRow): string {
  const d = row.data ?? {};
  const pick = ['name', 'role', 'kind', 'jobTitle', 'reason'].map((k) => d[k]).find((v) => typeof v === 'string' && v.length > 0);
  return typeof pick === 'string' ? `${row.entity} · ${pick}` : row.entity;
}

export function buildLiveData(rows: LiveRows, ctx: { readonly workspace: Workspace; readonly userId: string }): LiveData {
  const people: DirectoryPerson[] = rows.directory.map((r) => {
    const scheduleAvailable = r.shift_start !== null && r.shift_end !== null && r.rest_days !== null;
    // Internal sentinel only; consumers must not display or classify a redacted schedule.
    const [startH, startM] = hm(r.shift_start ?? '00:00');
    const [endH, endM] = hm(r.shift_end ?? '00:00');
    const night = scheduleAvailable && endH * 60 + endM <= startH * 60 + startM;
    return {
      id: UserId(r.user_id),
      name: r.display_name,
      title: r.job_title.length > 0 ? r.job_title : r.role_key ?? '',
      initials: initialsOf(r.display_name),
      hue: hueOf(r.user_id),
      role: isRole(r.role_key) ? r.role_key : 'staff',
      departmentId: (r.department_id ?? UNASSIGNED) as DepartmentId,
      scheduleAvailable,
      restDays: r.rest_days ?? [],
      shift: { start: [startH, startM], end: [endH, endM], ...(night ? { night: true } : {}) },
      location: r.location,
      ...(r.reports_to_user !== null ? { managerId: UserId(r.reports_to_user) } : {}),
      ...(r.team_id !== null ? { teamId: r.team_id as TeamId, teamName: r.team_name ?? '' } : {}),
    };
  });
  const departments: Record<string, string> = { [UNASSIGNED]: 'Unassigned' };
  for (const r of rows.directory) if (r.department_id !== null) departments[r.department_id] = r.department_name ?? 'Department';
  const nameOf = new Map(rows.directory.map((r) => [r.user_id, r.display_name]));

  const stepsBy = new Map<string, StepRow[]>();
  for (const s of rows.steps) stepsBy.set(s.request_id, [...(stepsBy.get(s.request_id) ?? []), s]);
  const requests: RequestRecord[] = rows.requests.map((r) => ({
    id: r.id,
    kind: r.kind,
    payload: { ...r.payload, kind: r.kind } as RequestPayload,
    submittedAt: r.created_at,
    state: {
      requesterId: UserId(r.requester_id),
      status: r.status,
      steps: (stepsBy.get(r.id) ?? [])
        .sort((a, b) => a.position - b.position)
        .map((s): ApprovalStep => ({
          level: s.level,
          approverId: UserId(s.approver_id),
          status: s.status,
          ...(s.decided_by !== null ? { decidedBy: UserId(s.decided_by) } : {}),
          ...(s.decided_at !== null ? { decidedAt: s.decided_at } : {}),
          ...(s.reason !== null ? { reason: s.reason } : {}),
        })),
    },
  }));

  const typeName = new Map(rows.leaveTypes.map((t) => [t.key, t.name]));
  const typeOrder = new Map(rows.leaveTypes.map((t, i) => [t.key, i]));
  const balances: Record<string, LeaveBalance[]> = {};
  for (const b of [...rows.balances].sort((x, y) => (typeOrder.get(x.leave_type) ?? 99) - (typeOrder.get(y.leave_type) ?? 99))) {
    const list = (balances[b.user_id] ??= []);
    list.push({
      leaveTypeId: b.leave_type,
      name: typeName.get(b.leave_type) ?? b.leave_type,
      available: num(b.available_days),
      entitled: num(b.entitled_days),
      hue: LEAVE_HUES[(typeOrder.get(b.leave_type) ?? list.length) % LEAVE_HUES.length] ?? 225,
    });
  }

  const policies: LeavePolicy[] = rows.leaveTypes.map((t) => ({
    leaveTypeId: t.key,
    name: t.name,
    nonWorkingWeekdays: [6, 7],
    allowHalfDays: t.allow_half_days,
    minNoticeDays: t.min_notice_days,
    maxConsecutiveDays: t.max_consecutive_days,
    allowNegativeBalance: false,
  }));

  const holidays: Record<string, { kind: HolidayKind; name: string }> = {};
  for (const h of rows.holidays) holidays[h.date] = { kind: h.kind, name: h.name };

  const tasks: Task[] = rows.workItems.map((w) => ({
    id: w.id,
    title: w.title,
    status: w.status,
    priority: w.priority,
    assigneeId: UserId(w.assignee_id),
    createdById: UserId(w.created_by),
    ...(w.due !== null ? { due: w.due as DateKey } : {}),
  }));

  const accountName = new Map(rows.accounts.map((a) => [a.id, a.name]));
  const deals: Deal[] = rows.deals.map((d) => ({
    id: d.id,
    name: d.name,
    account: accountName.get(d.account_id) ?? '—',
    ownerName: d.owner_id !== null ? nameOf.get(d.owner_id) ?? '—' : '—',
    stage: d.stage,
    amountMinor: num(d.amount_minor),
    currency: d.currency,
    closeDate: d.close_date ?? '',
  }));

  const organizationId = OrganizationId(ctx.workspace.organizationId);
  const events: AttendanceEvent[] = rows.events.map((e) => ({
    id: e.id,
    idempotencyKey: e.idempotency_key,
    organizationId,
    userId: UserId(e.user_id),
    type: e.type,
    occurredAt: new Date(e.occurred_at).toISOString(),
    source: e.source,
    ...(e.note !== null ? { note: e.note } : {}),
  }));

  return {
    dataset: {
      organization: { id: organizationId, name: ctx.workspace.name, timeZone: ctx.workspace.timeZone },
      actorId: UserId(ctx.userId),
      people,
      offboarded: rows.directory.filter((r) => r.status !== 'active').map((r) => UserId(r.user_id)),
      departments,
      events,
      requests,
      sheets: rows.sheets.map((s) => ({ userId: UserId(s.user_id), periodStart: s.period_start as DateKey, state: { status: s.status, history: [], version: s.version } })),
      balances,
      policies,
      holidays,
      tasks,
      lockedPeriods: rows.payrollPeriods.map((p) => p.period_start as DateKey),
      deals,
      audit: rows.audit.map((a) => ({ id: String(a.id), at: a.occurred_at, actorId: UserId(a.actor_id ?? ctx.userId), action: a.action, detail: auditDetail(a) })),
    },
    membershipOf: new Map(rows.directory.map((r) => [r.user_id, r.membership_id])),
    departmentIdOf: new Map(rows.directory.filter((r) => r.department_id !== null).map((r) => [r.department_name ?? '', r.department_id ?? ''])),
  };
}

// ------------------------------------------------------------------ errors

/**
 * Database errors carry a machine code before a colon ("self_approval: …")
 * or a SQLSTATE. Map both to the app's ApiError codes and readable text.
 */
export function toApiError(error: Pick<PostgrestError, 'code' | 'message'> | { code?: string; message: string }): ApiError {
  const message = error.message ?? '';
  const match = /^([a-z_]+)(?::\s*(.*))?$/s.exec(message.trim());
  const sqlState = error.code ?? '';
  const byState: Record<string, string> = { '42501': 'forbidden', '28000': 'not_authenticated', P0002: 'not_found', '22023': 'invalid', '23514': 'invalid', '23505': 'conflict', P0001: 'rejected' };
  const code = match?.[1] ?? byState[sqlState] ?? 'server_error';
  const text = match?.[2] !== undefined && match[2].length > 0 ? match[2] : message;
  if (code === 'forbidden' && (text === 'forbidden' || text.length === 0)) return new ApiError('forbidden', "You don't have access to do that.");
  const readable = text.length > 0 ? text.charAt(0).toUpperCase() + text.slice(1) : 'Something went wrong.';
  return new ApiError(code, readable);
}

// ------------------------------------------------------------------ fetching

const PAGE = 1000;
const MAX_ROWS = 50_000;

async function paged<T>(page: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: PostgrestError | null }>): Promise<T[]> {
  const out: T[] = [];
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await page(from, from + PAGE - 1);
    if (error !== null) throw toApiError(error);
    out.push(...(data ?? []));
    if ((data?.length ?? 0) < PAGE) return out;
    if (out.length >= MAX_ROWS) throw new ApiError('too_large', 'This organization has too much history to load at once.');
  }
}

async function single<T>(query: PromiseLike<{ data: T | null; error: PostgrestError | null }>): Promise<T> {
  const { data, error } = await query;
  if (error !== null) throw toApiError(error);
  return data as T;
}

export async function fetchWorkspaces(client: SupabaseClient): Promise<Workspace[]> {
  const rows = await single(
    client.rpc('my_workspaces') as unknown as PromiseLike<{
      data: { organization_id: string; name: string; time_zone: string; membership_id: string; role_key: string | null }[] | null;
      error: PostgrestError | null;
    }>,
  );
  return (rows ?? []).map((r) => ({ organizationId: r.organization_id, name: r.name, timeZone: r.time_zone, membershipId: r.membership_id, role: isRole(r.role_key) ? r.role_key : 'staff' }));
}

/** Everything the screens need, limited by the server to what this person may see. */
export async function fetchLiveRows(client: SupabaseClient, organizationId: string, today: DateKey): Promise<LiveRows> {
  const org = organizationId;
  const eventsSince = `${addDays(today, -7 * 11)}T00:00:00Z`; // reports cover 8+ weeks
  const requestsSince = `${addDays(today, -400)}T00:00:00Z`;
  const [directory, events, requests, steps, sheets, balances, leaveTypes, holidays, workItems, payrollPeriods, deals, accounts, audit] = await Promise.all([
    single(client.rpc('org_directory', { p_organization_id: org }) as unknown as PromiseLike<{ data: DirectoryRow[] | null; error: PostgrestError | null }>),
    paged<EventRow>((a, b) =>
      client.from('attendance_events').select('id,user_id,type,occurred_at,source,idempotency_key,note').eq('organization_id', org).gte('occurred_at', eventsSince).order('occurred_at').order('id').range(a, b),
    ),
    paged<RequestRow>((a, b) =>
      client.from('approval_requests').select('id,requester_id,kind,payload,status,created_at').eq('organization_id', org).gte('created_at', requestsSince).order('created_at').order('id').range(a, b),
    ),
    paged<StepRow>((a, b) =>
      client.from('approval_steps').select('request_id,position,level,approver_id,status,decided_by,decided_at,reason').eq('organization_id', org).order('request_id').order('position').range(a, b),
    ),
    paged<SheetRow>((a, b) => client.from('timesheets').select('user_id,period_start,status,version').eq('organization_id', org).order('period_start').order('user_id').range(a, b)),
    paged<BalanceRow>((a, b) => client.from('leave_balances').select('user_id,leave_type,available_days,entitled_days').eq('organization_id', org).order('user_id').order('leave_type').range(a, b)),
    paged<LeaveTypeRow>((a, b) => client.from('leave_types').select('key,name,allow_half_days,min_notice_days,max_consecutive_days').eq('organization_id', org).order('key').range(a, b)),
    paged<HolidayRow>((a, b) => client.from('holidays').select('date,kind,name').eq('organization_id', org).order('date').range(a, b)),
    paged<WorkItemRow>((a, b) => client.from('work_items').select('id,assignee_id,created_by,title,status,priority,due').eq('organization_id', org).order('created_at').order('id').range(a, b)),
    paged<{ period_start: string }>((a, b) => client.from('payroll_periods').select('period_start').eq('organization_id', org).order('period_start').range(a, b)),
    paged<DealRow>((a, b) => client.from('crm_deals').select('id,account_id,name,stage,amount_minor,currency,owner_id,close_date').eq('organization_id', org).order('id').range(a, b)),
    paged<{ id: string; name: string }>((a, b) => client.from('crm_accounts').select('id,name').eq('organization_id', org).order('id').range(a, b)),
    single(
      client.from('audit_events').select('id,actor_id,action,entity,data,occurred_at').eq('organization_id', org).order('occurred_at', { ascending: false }).limit(200) as unknown as PromiseLike<{
        data: AuditRow[] | null;
        error: PostgrestError | null;
      }>,
    ),
  ]);
  return {
    directory: directory ?? [],
    events,
    requests,
    steps,
    sheets,
    balances,
    leaveTypes,
    holidays,
    workItems,
    payrollPeriods,
    deals,
    accounts,
    audit: audit ?? [],
  };
}
