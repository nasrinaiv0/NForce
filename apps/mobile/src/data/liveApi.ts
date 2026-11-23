import { UserId, localDateKey, type DateKey, type Task } from '@nforce/core';
import type { SupabaseClient } from '@supabase/supabase-js';

import { buildLiveData, fetchLiveRows, toApiError, type LiveData, type Workspace } from './liveDataset';
import { createMockApi } from './mockApi';
import { ApiError, type NForceApi } from './types';

/**
 * The live backend: reads are computed from a snapshot of the organization
 * (row-level security limits it to what the signed-in person may see), using
 * the same rules as everywhere else. Every write is first checked against
 * that snapshot, so errors read the same as in the demo, then sent to the
 * database function that enforces it for real; the snapshot then reloads.
 */
export interface LiveApiOptions {
  readonly client: SupabaseClient;
  readonly workspace: Workspace;
  readonly userId: string;
  readonly now?: () => Date;
  /** Where clock events come from (`web` in browsers, `mobile` in the apps). */
  readonly source?: 'web' | 'mobile';
}

interface Loaded {
  readonly engine: NForceApi;
  readonly data: LiveData;
}

export function createLiveApi(options: LiveApiOptions): NForceApi {
  const { client, workspace } = options;
  const now = options.now ?? (() => new Date());
  const org = workspace.organizationId;
  const source = options.source ?? 'mobile';
  /** Notifications are computed, so "read" is remembered for this session. */
  const readIds = new Set<string>();

  let loading: Promise<Loaded> | undefined;
  const load = (): Promise<Loaded> =>
    (loading ??= (async () => {
      const rows = await fetchLiveRows(client, org, localDateKey(now(), workspace.timeZone) as DateKey);
      const data = buildLiveData(rows, { workspace, userId: options.userId });
      const engine = createMockApi({ dataset: data.dataset, latencyMs: 0, now, getPersona: () => 'staff' });
      if (readIds.size > 0) await engine.markNotificationsRead([...readIds]);
      return { engine, data };
    })().catch((error: unknown) => {
      loading = undefined;
      throw error;
    }));
  const refresh = () => {
    loading = undefined;
  };
  const engine = async () => (await load()).engine;

  const rpc = async <T = unknown>(fn: string, args: Record<string, unknown>): Promise<T> => {
    const { data, error } = await client.rpc(fn, args);
    if (error !== null) throw toApiError(error);
    return data as T;
  };
  /** Run a write; the snapshot always reloads afterwards (also on failure). */
  const write = async <T>(work: (loaded: Loaded) => Promise<T>): Promise<T> => {
    const loaded = await load();
    try {
      return await work(loaded);
    } finally {
      refresh();
    }
  };
  const membership = (data: LiveData, userId: string) => {
    const id = data.membershipOf.get(userId);
    if (id === undefined) throw new ApiError('not_found', 'That person is not in this organization.');
    return id;
  };
  const taskFromRow = (r: { id: string; title: string; status: Task['status']; priority: Task['priority']; assignee_id: string; created_by: string; due: string | null }): Task => ({
    id: r.id,
    title: r.title,
    status: r.status,
    priority: r.priority,
    assigneeId: UserId(r.assignee_id),
    createdById: UserId(r.created_by),
    ...(r.due !== null ? { due: r.due as DateKey } : {}),
  });

  return {
    // ------------------------------------------------------------ reads
    session: async () => (await engine()).session(),
    attendance: async () => (await engine()).attendance(),
    shifts: async (from, to) => (await engine()).shifts(from, to),
    teamSchedule: async (from, to) => (await engine()).teamSchedule(from, to),
    tasks: async () => (await engine()).tasks(),
    balances: async () => (await engine()).balances(),
    leaveTypes: async () => (await engine()).leaveTypes(),
    myRequests: async () => (await engine()).myRequests(),
    previewTimeOff: async (input) => (await engine()).previewTimeOff(input),
    approverPreview: async () => (await engine()).approverPreview(),
    approvals: async () => (await engine()).approvals(),
    timesheet: async (params) => (await engine()).timesheet(params),
    team: async () => (await engine()).team(),
    teamPulse: async () => (await engine()).teamPulse(),
    attendanceReport: async (params) => (await engine()).attendanceReport(params),
    executiveReport: async (params) => (await engine()).executiveReport(params),
    directory: async () => (await engine()).directory(),
    profile: async (userId) => (await engine()).profile(userId),
    payroll: async (periodStart) => (await engine()).payroll(periodStart),
    admin: async () => (await engine()).admin(),
    deals: async () => (await engine()).deals(),
    notifications: async () => (await engine()).notifications(),
    markNotificationsRead: async (ids) => {
      for (const id of ids) readIds.add(id);
      await (await engine()).markNotificationsRead(ids);
    },

    // ------------------------------------------------------------ writes
    clock: (type, idempotencyKey) =>
      write(async ({ engine: e }) => {
        await e.clock(type, idempotencyKey);
        await rpc('record_attendance_event', { p_organization_id: org, p_type: type, p_idempotency_key: idempotencyKey, p_source: source });
        refresh();
        return (await engine()).attendance();
      }),

    createTask: (input) =>
      write(async ({ engine: e }) => {
        await e.createTask(input);
        const row = await rpc<Parameters<typeof taskFromRow>[0]>('create_work_item', {
          p_organization_id: org,
          p_title: input.title.trim(),
          p_priority: input.priority,
          p_due: input.due ?? null,
        });
        return taskFromRow(row);
      }),

    setTaskDone: (id, done) =>
      write(async () => taskFromRow(await rpc<Parameters<typeof taskFromRow>[0]>('set_work_item_status', { p_id: id, p_status: done ? 'done' : 'todo' }))),

    requestTimeOff: (input) =>
      write(async ({ engine: e }) => {
        const draft = await e.requestTimeOff(input);
        const row = await rpc<{ id: string }>('submit_request', { p_organization_id: org, p_kind: draft.kind, p_payload: draft.payload });
        refresh();
        return (await (await engine()).myRequests()).find((r) => r.id === row.id) ?? draft;
      }),

    requestOvertime: (input) =>
      write(async ({ engine: e }) => {
        const draft = await e.requestOvertime(input);
        const row = await rpc<{ id: string }>('submit_request', { p_organization_id: org, p_kind: draft.kind, p_payload: draft.payload });
        refresh();
        return (await (await engine()).myRequests()).find((r) => r.id === row.id) ?? draft;
      }),

    decide: (id, decision, reason) =>
      write(async ({ engine: e }) => {
        await e.decide(id, decision, reason);
        await rpc('decide_request', { p_request_id: id, p_decision: decision, p_reason: reason ?? null });
      }),

    timesheetAction: (action, periodStart, reason) =>
      write(async ({ engine: e }) => {
        if (action !== 'submit') throw new ApiError('invalid', 'Timesheets are approved from the Approvals inbox.');
        const sheet = await e.timesheet({ periodStart });
        await e.timesheetAction(action, periodStart, reason);
        await rpc('submit_timesheet', {
          p_organization_id: org,
          p_period_start: periodStart,
          p_worked_minutes: sheet.totals.worked,
          p_overtime_minutes: sheet.totals.overtime,
        });
      }),

    createEmployee: (input) =>
      write(async ({ engine: e, data }) => {
        const email = input.email?.trim() ?? '';
        if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw new ApiError('invalid', 'Enter the email address of their NForce account.');
        await e.createEmployee(input);
        const row = await rpc<{ user_id: string }>('add_member_by_email', {
          p_organization_id: org,
          p_email: email,
          p_role_key: input.role,
          p_reports_to_user: input.managerId,
          p_department_id: data.departmentIdOf.get(input.department) ?? null,
          p_job_title: input.title.trim(),
        });
        refresh();
        const added = (await (await engine()).directory()).find((d) => d.person.id === row.user_id);
        if (added === undefined) throw new ApiError('not_found', 'The employee was added, but you cannot see them in the directory.');
        return added;
      }),

    updateEmployee: (id, patch) =>
      write(async ({ engine: e, data }) => {
        const before = data.dataset.people.find((p) => p.id === id);
        if (before === undefined) throw new ApiError('not_found', 'That person is not in this organization.');
        await e.updateEmployee(id, patch);
        const mid = membership(data, id);
        if (patch.role !== undefined && patch.role !== before.role) await rpc('assign_role', { p_membership_id: mid, p_role_key: patch.role });
        if (patch.managerId !== undefined && patch.managerId !== before.managerId) {
          await rpc('update_member', {
            p_membership_id: mid,
            p_reports_to: membership(data, patch.managerId),
            p_department_id: before.departmentId === 'unassigned' ? null : before.departmentId,
          });
        }
        if (patch.title !== undefined && patch.title.trim().length > 1 && patch.title.trim() !== before.title) {
          await rpc('update_member_details', { p_membership_id: mid, p_job_title: patch.title.trim() });
        }
        refresh();
        const updated = (await (await engine()).directory()).find((d) => d.person.id === id);
        if (updated === undefined) throw new ApiError('not_found', 'That person is not in this organization.');
        return updated;
      }),

    offboardEmployee: (id) =>
      write(async ({ engine: e, data }) => {
        await e.offboardEmployee(id);
        await rpc('offboard_member', { p_membership_id: membership(data, id) });
      }),

    lockPayroll: (periodStart) =>
      write(async ({ engine: e }) => {
        await e.lockPayroll(periodStart);
        await rpc('lock_payroll_period', { p_organization_id: org, p_period_start: periodStart });
      }),

    moveDeal: (id, stage, reason) =>
      write(async ({ engine: e }) => {
        const moved = await e.moveDeal(id, stage, reason);
        await rpc('move_deal', { p_deal_id: id, p_stage: stage, p_reason: reason ?? null });
        return moved;
      }),
  };
}
