import { UserId } from '@nforce/core';
import type { SupabaseClient } from '@supabase/supabase-js';
import { describe, expect, it } from 'vitest';

import { createLiveApi } from '@/data/liveApi';
import { buildLiveData, fetchLiveRows, toApiError, type DirectoryRow, type LiveRows, type Workspace } from '@/data/liveDataset';
import { ApiError } from '@/data/types';

/**
 * The live backend against a simulated Supabase client: rows in, the same
 * screens out, and every write sent to the right database function with the
 * right arguments. (End-to-end checks against the real project run once the
 * project is reachable.)
 */
const ORG = 'b1000000-0000-0000-0000-000000000001';
const NOW = new Date('2026-11-24T03:00:00Z'); // Tue 11:00 in Manila
const U = (n: number) => `a0000000-0000-0000-0000-00000000000${n}`;
const M = (n: number) => `c0000000-0000-0000-0000-00000000000${n}`;
const workspace: Workspace = { organizationId: ORG, name: 'Bayside Logistics', timeZone: 'Asia/Manila', membershipId: M(1), role: 'owner' };

const person = (n: number, name: string, role: string, boss: number | null, extra: Partial<DirectoryRow> = {}): DirectoryRow => ({
  user_id: U(n),
  membership_id: M(n),
  display_name: name,
  job_title: `${role} title`,
  location: 'Cebu Port',
  status: 'active',
  department_id: 'd1',
  department_name: 'Operations',
  team_id: null,
  team_name: null,
  reports_to_user: boss === null ? null : U(boss),
  role_key: role,
  shift_start: '09:00:00',
  shift_end: '18:00:00',
  rest_days: [6, 7],
  ...extra,
});

function rows(): LiveRows {
  return {
    directory: [
      person(1, 'Ana Reyes', 'owner', null),
      person(2, 'Ben Cruz', 'manager', 1),
      person(3, 'Cy Tan', 'supervisor', 2),
      person(4, 'Dee Lim', 'staff', 3, { shift_start: '22:00:00', shift_end: '07:00:00' }),
      person(5, 'Eve Santos', 'staff', 3, { status: 'ended' }),
    ],
    events: [
      { id: 'e1', user_id: U(4), type: 'clock_in', occurred_at: '2026-11-23T14:02:00+00:00', source: 'mobile', idempotency_key: 'k-00000001', note: null },
      { id: 'e2', user_id: U(4), type: 'clock_out', occurred_at: '2026-11-23T23:01:00+00:00', source: 'mobile', idempotency_key: 'k-00000002', note: null },
    ],
    requests: [
      {
        id: 'r1',
        requester_id: U(4),
        kind: 'leave',
        payload: { kind: 'leave', leaveTypeId: 'vacation', leaveType: 'Vacation', start: '2026-12-14', end: '2026-12-15', days: 2 },
        status: 'pending',
        created_at: '2026-11-22T01:00:00Z',
      },
    ],
    steps: [
      { request_id: 'r1', position: 2, level: 'manager', approver_id: U(2), status: 'waiting', decided_by: null, decided_at: null, reason: null },
      { request_id: 'r1', position: 1, level: 'supervisor', approver_id: U(3), status: 'pending', decided_by: null, decided_at: null, reason: null },
    ],
    sheets: [{ user_id: U(4), period_start: '2026-11-16', status: 'approved', version: 3 }],
    balances: [
      { user_id: U(4), leave_type: 'sick', available_days: '7.00', entitled_days: '7.00' },
      { user_id: U(4), leave_type: 'vacation', available_days: '13.50', entitled_days: '15.00' },
    ],
    leaveTypes: [
      { key: 'sick', name: 'Sick leave', allow_half_days: true, min_notice_days: 0, max_consecutive_days: 10 },
      { key: 'vacation', name: 'Vacation', allow_half_days: true, min_notice_days: 3, max_consecutive_days: 15 },
    ],
    holidays: [{ date: '2026-11-30', kind: 'regular', name: 'Bonifacio Day' }],
    workItems: [{ id: 'w1', assignee_id: U(4), created_by: U(3), title: 'Load truck 12', status: 'todo', priority: 'high', due: '2026-11-24' }],
    payrollPeriods: [{ period_start: '2026-11-09' }],
    deals: [{ id: 'deal1', account_id: 'acc1', name: 'Port renewal', stage: 'proposal', amount_minor: '120000000', currency: 'PHP', owner_id: U(1), close_date: '2026-12-20' }],
    accounts: [{ id: 'acc1', name: 'Harbor Freight' }],
    audit: [{ id: 7, actor_id: U(1), action: 'member.added', entity: 'membership', data: { role: 'staff' }, occurred_at: '2026-11-20T00:00:00Z' }],
  };
}

describe('mapping database rows', () => {
  const live = buildLiveData(rows(), { workspace, userId: U(4) });
  const ds = live.dataset;

  it('maps people, night shifts, reporting lines and departures', () => {
    const dee = ds.people.find((p) => p.id === U(4));
    expect(dee).toMatchObject({ name: 'Dee Lim', initials: 'DL', role: 'staff', managerId: U(3), shift: { start: [22, 0], end: [7, 0], night: true } });
    expect(ds.people.find((p) => p.id === U(2))?.shift.night).toBeUndefined();
    expect(ds.offboarded).toEqual([U(5)]);
    expect(ds.departments.d1).toBe('Operations');
    expect(live.membershipOf.get(U(3))).toBe(M(3));
    expect(live.departmentIdOf.get('Operations')).toBe('d1');
  });

  it('orders approval steps, converts numbers and keeps leave types in order', () => {
    expect(ds.requests[0]?.state.steps.map((s) => `${s.level}:${s.status}`)).toEqual(['supervisor:pending', 'manager:waiting']);
    expect(ds.balances[U(4)]?.map((b) => [b.leaveTypeId, b.available, b.entitled])).toEqual([
      ['sick', 7, 7],
      ['vacation', 13.5, 15],
    ]);
    expect(ds.deals[0]).toMatchObject({ account: 'Harbor Freight', ownerName: 'Ana Reyes', amountMinor: 120000000 });
    expect(ds.holidays['2026-11-30']?.name).toBe('Bonifacio Day');
    expect(ds.audit[0]?.detail).toBe('membership · staff');
  });
});

describe('database errors', () => {
  it('uses the code before the colon and keeps the explanation', () => {
    const e = toApiError({ code: '42501', message: 'self_approval: you cannot decide your own request' });
    expect(e).toBeInstanceOf(ApiError);
    expect(e).toMatchObject({ code: 'self_approval', message: 'You cannot decide your own request' });
  });
  it('maps bare SQL states to app codes', () => {
    expect(toApiError({ code: '42501', message: 'forbidden' })).toMatchObject({ code: 'forbidden', message: "You don't have access to do that." });
    expect(toApiError({ code: '22023', message: 'invalid manager: choose an active member of this organization' })).toMatchObject({ code: 'invalid' });
    expect(toApiError({ code: '23514', message: 'reporting line would contain a cycle' })).toMatchObject({ code: 'invalid' });
  });
});

// ------------------------------------------------------------------ simulated client

type Row = Record<string, unknown>;
interface RpcResult {
  data?: unknown;
  error?: { code: string; message: string };
}

function fakeClient(state: LiveRows, rpcs: Record<string, (args: Row) => RpcResult> = {}) {
  const calls: { fn: string; args: Row }[] = [];
  const tables: Record<string, readonly unknown[]> = {
    attendance_events: state.events,
    approval_requests: state.requests,
    approval_steps: state.steps,
    timesheets: state.sheets,
    leave_balances: state.balances,
    leave_types: state.leaveTypes,
    holidays: state.holidays,
    work_items: state.workItems,
    payroll_periods: state.payrollPeriods,
    crm_deals: state.deals,
    crm_accounts: state.accounts,
    audit_events: state.audit,
  };
  const query = (all: readonly unknown[]) => {
    let rows = [...all] as Row[];
    const result = () => ({ data: rows, error: null });
    const q = {
      select: () => q,
      eq: (col: string, v: unknown) => ((rows = rows.filter((r) => !(col in r) || r[col] === v)), q),
      gte: (col: string, v: string) => ((rows = rows.filter((r) => !(col in r) || String(r[col]) >= v)), q),
      order: () => q,
      limit: (n: number) => ((rows = rows.slice(0, n)), q),
      range: (a: number, b: number) => Promise.resolve({ data: rows.slice(a, b + 1), error: null }),
      then: (ok: (v: unknown) => unknown, bad?: (e: unknown) => unknown) => Promise.resolve(result()).then(ok, bad),
    };
    return q;
  };
  const client = {
    from: (t: string) => query(tables[t] ?? []),
    rpc: (fn: string, args: Row = {}) => {
      if (fn === 'org_directory') return Promise.resolve({ data: state.directory, error: null });
      calls.push({ fn, args });
      const r = rpcs[fn]?.(args) ?? {};
      return Promise.resolve({ data: r.data ?? null, error: r.error ?? null });
    },
  };
  return { client: client as unknown as SupabaseClient, calls };
}

const make = (userId: string, rpcs?: Record<string, (args: Row) => RpcResult>) => {
  const state = rows();
  const { client, calls } = fakeClient(state, rpcs);
  const api = createLiveApi({ client, workspace, userId, now: () => NOW, source: 'web' });
  return { api, calls, state };
};

describe('live backend', () => {
  it('computes screens from the database rows', async () => {
    const { api } = make(U(4));
    const session = await api.session();
    expect(session.user.name).toBe('Dee Lim');
    expect(session.organization).toMatchObject({ id: ORG, name: 'Bayside Logistics', timeZone: 'Asia/Manila' });
    expect((await api.tasks()).map((t) => t.title)).toEqual(['Load truck 12']);
    expect((await api.leaveTypes()).map((l) => l.name)).toEqual(['Sick leave', 'Vacation']);
    expect((await api.myRequests())[0]?.steps.map((s) => s.approver.name)).toEqual(['Cy Tan', 'Ben Cruz']);
    // The night shift that started Monday 22:02 belongs to Monday.
    const sheet = await api.timesheet({ periodStart: '2026-11-23' });
    expect(sheet.days[0]).toMatchObject({ date: '2026-11-23', nightMinutes: expect.any(Number) });
    expect(sheet.days[0]?.nightMinutes).toBeGreaterThan(400);
  });

  it('clocks in through record_attendance_event and reloads', async () => {
    const { api, calls, state } = make(U(3), {
      record_attendance_event: (a) => {
        (state.events as unknown as Row[]).push({ id: 'e9', user_id: U(3), type: a.p_type, occurred_at: NOW.toISOString(), source: 'web', idempotency_key: a.p_idempotency_key, note: null });
        return { data: {} };
      },
    });
    const snap = await api.clock('clock_in', 'key-12345678');
    expect(calls).toEqual([{ fn: 'record_attendance_event', args: { p_organization_id: ORG, p_type: 'clock_in', p_idempotency_key: 'key-12345678', p_source: 'web' } }]);
    expect(snap.status).toBe('working');
  });

  it('submits a leave request with the full payload', async () => {
    const { api, calls } = make(U(4), { submit_request: () => ({ data: { id: 'r2' } }) });
    await api.requestTimeOff({ kind: 'leave', leaveTypeId: 'vacation', start: '2026-12-21', end: '2026-12-22' });
    expect(calls[0]).toEqual({
      fn: 'submit_request',
      args: { p_organization_id: ORG, p_kind: 'leave', p_payload: { kind: 'leave', leaveTypeId: 'vacation', leaveType: 'Vacation', start: '2026-12-21', end: '2026-12-22', days: 2 } },
    });
  });

  it('checks a decision locally before calling decide_request, and surfaces database errors', async () => {
    const { api, calls } = make(U(3), { decide_request: () => ({ error: { code: '42501', message: 'forbidden: you no longer have approval access for this person' } }) });
    await expect(api.decide('r1', 'return')).rejects.toMatchObject({ code: 'reason_required' });
    expect(calls).toEqual([]);
    await expect(api.decide('r1', 'approve')).rejects.toMatchObject({ code: 'forbidden', message: 'You no longer have approval access for this person' });
    expect(calls).toEqual([{ fn: 'decide_request', args: { p_request_id: 'r1', p_decision: 'approve', p_reason: null } }]);
  });

  it('never lets someone decide their own request, even before reaching the database', async () => {
    const { api, calls } = make(U(4));
    await expect(api.decide('r1', 'approve')).rejects.toMatchObject({ code: 'self_approval' });
    expect(calls).toEqual([]);
  });

  it('updates role and reporting line with membership ids', async () => {
    const { api, calls } = make(U(1));
    await api.updateEmployee(UserId(U(4)), { role: 'supervisor', managerId: UserId(U(2)) });
    expect(calls).toEqual([
      { fn: 'assign_role', args: { p_membership_id: M(4), p_role_key: 'supervisor' } },
      { fn: 'update_member', args: { p_membership_id: M(4), p_reports_to: M(2), p_department_id: 'd1' } },
    ]);
  });

  it('adds employees by account email and requires one', async () => {
    const { api, calls } = make(U(1), { add_member_by_email: () => ({ data: { user_id: U(4) } }) });
    const input = { name: 'Fay Uy', title: 'Dispatcher', role: 'staff' as const, managerId: UserId(U(3)), department: 'Operations' };
    await expect(api.createEmployee(input)).rejects.toMatchObject({ code: 'invalid' });
    await api.createEmployee({ ...input, email: ' fay@example.com ' });
    expect(calls).toEqual([
      {
        fn: 'add_member_by_email',
        args: { p_organization_id: ORG, p_email: 'fay@example.com', p_role_key: 'staff', p_reports_to_user: U(3), p_department_id: 'd1', p_job_title: 'Dispatcher' },
      },
    ]);
  });

  it('offboards by membership and refuses people the viewer cannot manage', async () => {
    const owner = make(U(1));
    await owner.api.offboardEmployee(UserId(U(4)));
    expect(owner.calls).toEqual([{ fn: 'offboard_member', args: { p_membership_id: M(4) } }]);
    const manager = make(U(2));
    await expect(manager.api.offboardEmployee(UserId(U(4)))).rejects.toBeInstanceOf(ApiError);
    expect(manager.calls).toEqual([]);
  });

  it('creates and completes tasks through the work item functions', async () => {
    const row = { id: 'w2', title: 'Check manifests', status: 'todo', priority: 'normal', assignee_id: U(4), created_by: U(4), due: null };
    const { api, calls } = make(U(4), { create_work_item: () => ({ data: row }), set_work_item_status: () => ({ data: { ...row, status: 'done' } }) });
    expect(await api.createTask({ title: ' Check manifests ', priority: 'normal' })).toMatchObject({ id: 'w2', title: 'Check manifests' });
    expect((await api.setTaskDone('w2', true)).status).toBe('done');
    expect(calls.map((c) => c.fn)).toEqual(['create_work_item', 'set_work_item_status']);
    expect(calls[0]?.args).toEqual({ p_organization_id: ORG, p_title: 'Check manifests', p_priority: 'normal', p_due: null });
  });

  it('pages through more than 1,000 rows', async () => {
    const state = rows();
    const many = Array.from({ length: 2500 }, (_, i) => ({
      id: `x${i}`,
      user_id: U(4),
      type: i % 2 === 0 ? ('clock_in' as const) : ('clock_out' as const),
      occurred_at: new Date(Date.parse('2026-10-01T01:00:00Z') + i * 60_000).toISOString(),
      source: 'mobile' as const,
      idempotency_key: `k-${String(i).padStart(8, '0')}`,
      note: null,
    }));
    const { client } = fakeClient({ ...state, events: many });
    expect((await fetchLiveRows(client, ORG, '2026-11-24')).events).toHaveLength(2500);
    const api = createLiveApi({ client, workspace, userId: U(1), now: () => NOW });
    expect((await api.attendanceReport({ scope: 'org', weeks: 8 })).metrics.headcount).toBeGreaterThan(0);
  });
});
