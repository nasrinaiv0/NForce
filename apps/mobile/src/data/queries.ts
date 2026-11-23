import { MutationCache, QueryCache, QueryClient, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { addDays, type AttendanceEventType, type DateKey, type TimesheetAction, type UserId } from '@nforce/core';
import { randomUUID } from 'expo-crypto';
import { Platform } from 'react-native';

import { activeWorkspace, backendStore, isLive } from '@/state/backend';
import { preferencesStore } from '@/state/preferences';
import { createLiveApi } from './liveApi';
import { createMockApi } from './mockApi';
import { supabase } from './supabase';
import { ApiError, type AttendanceSnapshot, type EmployeeInput, type NForceApi, type NewTaskInput, type OvertimeInput, type ReportScope, type TimeOffInput } from './types';

/**
 * Server-state layer (TanStack Query).
 *
 * - One query-key factory so invalidation is precise and typo-proof.
 * - Business errors (`ApiError`) are never retried; transient errors retry
 *   with exponential backoff.
 * - Every attendance mutation carries a client-generated idempotency key, so a
 *   retry after a timeout can never double-clock.
 */

const demoApi = createMockApi({ getPersona: () => preferencesStore.get().persona });
let live: { key: string; api: NForceApi } | undefined;

/**
 * The backend in use right now: the signed-in person's live workspace, or the
 * demo organization. Screens never know which one they are talking to.
 */
export function currentApi(): NForceApi {
  const state = backendStore.get();
  const workspace = activeWorkspace(state);
  if (!isLive() || state.userId === undefined || workspace === undefined) return demoApi;
  const key = `${state.userId}|${workspace.organizationId}`;
  if (live?.key !== key) live = { key, api: createLiveApi({ client: supabase(), workspace, userId: state.userId, source: Platform.OS === 'web' ? 'web' : 'mobile' }) };
  return live.api;
}

export const api: NForceApi = new Proxy({} as NForceApi, {
  get: (_target, property) => Reflect.get(currentApi(), property),
});

export const keys = {
  all: ['nforce'] as const,
  session: () => [...keys.all, 'session'] as const,
  attendance: () => [...keys.all, 'attendance'] as const,
  shifts: (from: DateKey, to: DateKey) => [...keys.all, 'shifts', from, to] as const,
  roster: (from: DateKey, to: DateKey) => [...keys.all, 'roster', from, to] as const,
  tasks: () => [...keys.all, 'tasks'] as const,
  balances: () => [...keys.all, 'balances'] as const,
  requests: () => [...keys.all, 'my-requests'] as const,
  approverPreview: () => [...keys.all, 'approver-preview'] as const,
  approvals: () => [...keys.all, 'approvals'] as const,
  timesheet: (userId?: UserId, periodStart?: DateKey) => [...keys.all, 'timesheet', userId ?? 'me', periodStart ?? 'current'] as const,
  timesheets: () => [...keys.all, 'timesheet'] as const,
  team: () => [...keys.all, 'team'] as const,
  attendanceReport: (scope: ReportScope, weeks: number) => [...keys.all, 'attendance-report', scope, weeks] as const,
  executiveReport: (weeks: number) => [...keys.all, 'executive-report', weeks] as const,
  directory: () => [...keys.all, 'directory'] as const,
  profile: (id: UserId) => [...keys.all, 'profile', id] as const,
  payroll: (start?: DateKey) => [...keys.all, 'payroll', start ?? 'latest'] as const,
  admin: () => [...keys.all, 'admin'] as const,
  deals: () => [...keys.all, 'deals'] as const,
  notifications: () => [...keys.all, 'notifications'] as const,
  teamPulse: () => [...keys.all, 'team-pulse'] as const,
};

const isBusinessError = (e: unknown) => e instanceof ApiError;

export const queryClient = new QueryClient({
  queryCache: new QueryCache({
    onError: (error) => {
      if (!isBusinessError(error)) console.warn('[query]', error);
    },
  }),
  mutationCache: new MutationCache({
    onError: (error) => {
      if (!isBusinessError(error)) console.warn('[mutation]', error);
    },
  }),
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      gcTime: 5 * 60_000,
      retry: (count, error) => !isBusinessError(error) && count < 3,
      retryDelay: (attempt) => Math.min(1000 * 2 ** attempt, 8000),
      refetchOnWindowFocus: true,
    },
    mutations: { retry: 0 },
  },
});

/** Reset all server state, e.g. after switching workspace/persona. */
export function resetSession(): Promise<void> {
  return queryClient.resetQueries({ queryKey: keys.all });
}

// ------------------------------------------------------------------ queries

export const useSession = () => useQuery({ queryKey: keys.session(), queryFn: api.session, staleTime: Infinity });
export const useAttendance = () => useQuery({ queryKey: keys.attendance(), queryFn: api.attendance });
export const useTasks = () => useQuery({ queryKey: keys.tasks(), queryFn: api.tasks });
export const useBalances = () => useQuery({ queryKey: keys.balances(), queryFn: api.balances });
export const useMyRequests = () => useQuery({ queryKey: keys.requests(), queryFn: api.myRequests });
export const useApproverPreview = () => useQuery({ queryKey: keys.approverPreview(), queryFn: api.approverPreview, staleTime: Infinity, retry: false });
export const useTimesheet = (userId?: UserId, periodStart?: DateKey) =>
  useQuery({
    queryKey: keys.timesheet(userId, periodStart),
    queryFn: () => api.timesheet({ ...(userId !== undefined ? { userId } : {}), ...(periodStart !== undefined ? { periodStart } : {}) }),
  });
export const useAttendanceReport = (scope: ReportScope, weeks: number) =>
  useQuery({ queryKey: keys.attendanceReport(scope, weeks), queryFn: () => api.attendanceReport({ scope, weeks }), staleTime: 5 * 60_000 });
export const useExecutiveReport = (weeks: number, enabled = true) =>
  useQuery({ queryKey: keys.executiveReport(weeks), queryFn: () => api.executiveReport({ weeks }), staleTime: 5 * 60_000, enabled });
export const useDirectory = () => useQuery({ queryKey: keys.directory(), queryFn: api.directory, staleTime: 10 * 60_000 });
export const useProfile = (id: UserId, enabled = true) => useQuery({ queryKey: keys.profile(id), queryFn: () => api.profile(id), enabled });
export const usePayroll = (start?: DateKey) => useQuery({ queryKey: keys.payroll(start), queryFn: () => api.payroll(start) });
export const useAdmin = () => useQuery({ queryKey: keys.admin(), queryFn: api.admin });
export const useDeals = () => useQuery({ queryKey: keys.deals(), queryFn: api.deals });
export const useNotifications = () => useQuery({ queryKey: keys.notifications(), queryFn: api.notifications, refetchInterval: 60_000 });

export function useLockPayroll() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (start: DateKey) => api.lockPayroll(start),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: [...keys.all, 'payroll'] });
      void qc.invalidateQueries({ queryKey: keys.timesheets() });
    },
  });
}

/** Employee management invalidates everything that depends on the org chart. */
function usePeopleMutation<TArgs>(fn: (args: TArgs) => Promise<unknown>) {
  const qc = useQueryClient();
  return useMutation({ mutationFn: fn, onSuccess: () => qc.invalidateQueries({ queryKey: keys.all }) });
}
export const useCreateEmployee = () => usePeopleMutation((input: EmployeeInput) => api.createEmployee(input));
export const useUpdateEmployee = () =>
  usePeopleMutation(({ id, patch }: { id: UserId; patch: Partial<Omit<EmployeeInput, 'name'>> }) => api.updateEmployee(id, patch));
export const useOffboardEmployee = () => usePeopleMutation((id: UserId) => api.offboardEmployee(id));

export function useMarkNotificationsRead() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (ids: readonly string[]) => api.markNotificationsRead(ids),
    onSuccess: () => qc.invalidateQueries({ queryKey: keys.notifications() }),
  });
}

export const useTeam = (enabled = true) => useQuery({ queryKey: keys.team(), queryFn: api.team, enabled, refetchInterval: 60_000 });

export const useTeamSchedule = (from: DateKey, days: number, enabled = true) => {
  const to = addDays(from, days - 1);
  return useQuery({ queryKey: keys.roster(from, to), queryFn: () => api.teamSchedule(from, to), staleTime: 5 * 60_000, enabled });
};
export const useLeaveTypes = () => useQuery({ queryKey: [...keys.all, 'leave-types'] as const, queryFn: api.leaveTypes, staleTime: Infinity });
export const useShifts = (from: DateKey, days: number) => {
  const to = addDays(from, days - 1);
  return useQuery({ queryKey: keys.shifts(from, to), queryFn: () => api.shifts(from, to), staleTime: 5 * 60_000 });
};

export const useApprovals = (enabled = true) =>
  useQuery({ queryKey: keys.approvals(), queryFn: api.approvals, enabled });

export const useTeamPulse = (enabled = true) =>
  useQuery({ queryKey: keys.teamPulse(), queryFn: api.teamPulse, enabled, refetchInterval: 60_000 });

// ------------------------------------------------------------------ mutations

export function useClock() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ type, key }: { type: AttendanceEventType; key: string }) => api.clock(type, key),
    onSuccess: (snapshot) => {
      qc.setQueryData<AttendanceSnapshot>(keys.attendance(), snapshot);
      void qc.invalidateQueries({ queryKey: keys.timesheets() });
    },
  });
}

/** Generates the idempotency key once per user intent (not per retry). */
export const newIdempotencyKey = (): string => randomUUID();

export function useSetTaskDone() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, done }: { id: string; done: boolean }) => api.setTaskDone(id, done),
    onMutate: async ({ id, done }) => {
      await qc.cancelQueries({ queryKey: keys.tasks() });
      const previous = qc.getQueryData<Awaited<ReturnType<typeof api.tasks>>>(keys.tasks());
      qc.setQueryData(keys.tasks(), previous?.map((t) => (t.id === id ? { ...t, status: done ? 'done' : 'todo' } : t)));
      return { previous };
    },
    onError: (_e, _v, ctx) => {
      if (ctx?.previous !== undefined) qc.setQueryData(keys.tasks(), ctx.previous);
    },
    onSettled: () => qc.invalidateQueries({ queryKey: keys.tasks() }),
  });
}

export function useCreateTask() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (input: NewTaskInput) => api.createTask(input),
    onSuccess: () => qc.invalidateQueries({ queryKey: keys.tasks() }),
  });
}

export function useRequestTimeOff() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (input: TimeOffInput) => api.requestTimeOff(input),
    onSuccess: () => qc.invalidateQueries({ queryKey: keys.requests() }),
  });
}

export function useRequestOvertime() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (input: OvertimeInput) => api.requestOvertime(input),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: keys.requests() });
      void qc.invalidateQueries({ queryKey: keys.timesheets() });
    },
  });
}

export function useDecide() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, decision, reason }: { id: string; decision: 'approve' | 'return'; reason?: string }) =>
      api.decide(id, decision, reason),
    onMutate: async ({ id }) => {
      await qc.cancelQueries({ queryKey: keys.approvals() });
      const previous = qc.getQueryData<Awaited<ReturnType<typeof api.approvals>>>(keys.approvals());
      qc.setQueryData(keys.approvals(), previous?.map((a) => (a.id === id ? { ...a, canDecide: false } : a)));
      return { previous };
    },
    onError: (_e, _v, ctx) => {
      if (ctx?.previous !== undefined) qc.setQueryData(keys.approvals(), ctx.previous);
    },
    onSettled: () => {
      for (const key of [keys.approvals(), keys.tasks(), keys.team(), keys.timesheets(), keys.balances()]) {
        void qc.invalidateQueries({ queryKey: key });
      }
    },
  });
}

export function useTimesheetAction() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ action, periodStart, reason }: { action: TimesheetAction; periodStart: DateKey; reason?: string }) =>
      api.timesheetAction(action, periodStart, reason),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: keys.timesheets() });
      void qc.invalidateQueries({ queryKey: keys.requests() });
    },
  });
}

/** User-safe message for any thrown value. */
export function errorMessage(error: unknown, fallback: string): string {
  return error instanceof ApiError ? error.message : fallback;
}
