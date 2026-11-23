import { MutationCache, QueryCache, QueryClient, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { addDays, type AttendanceEventType, type DateKey, type TimesheetAction } from '@nforce/core';
import { randomUUID } from 'expo-crypto';

import { preferencesStore } from '@/state/preferences';
import { createMockApi } from './mockApi';
import { ApiError, type AttendanceSnapshot, type NewTaskInput, type TimeOffInput } from './types';

/**
 * Server-state layer (TanStack Query).
 *
 * - One query-key factory so invalidation is precise and typo-proof.
 * - Business errors (`ApiError`) are never retried; transient errors retry
 *   with exponential backoff.
 * - Every attendance mutation carries a client-generated idempotency key, so a
 *   retry after a timeout can never double-clock.
 */

export const api = createMockApi({ getPersona: () => preferencesStore.get().persona });

export const keys = {
  all: ['nforce'] as const,
  session: () => [...keys.all, 'session'] as const,
  attendance: () => [...keys.all, 'attendance'] as const,
  shifts: (from: DateKey, to: DateKey) => [...keys.all, 'shifts', from, to] as const,
  tasks: () => [...keys.all, 'tasks'] as const,
  balances: () => [...keys.all, 'balances'] as const,
  timeOff: () => [...keys.all, 'timeoff'] as const,
  approvals: () => [...keys.all, 'approvals'] as const,
  timesheet: () => [...keys.all, 'timesheet'] as const,
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
export const useTimeOffRequests = () => useQuery({ queryKey: keys.timeOff(), queryFn: api.timeOffRequests });
export const useTimesheet = () => useQuery({ queryKey: keys.timesheet(), queryFn: api.timesheet });

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
      void qc.invalidateQueries({ queryKey: keys.timesheet() });
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
    onSuccess: () => qc.invalidateQueries({ queryKey: keys.timeOff() }),
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
      qc.setQueryData(keys.approvals(), previous?.filter((a) => a.id !== id));
      return { previous };
    },
    onError: (_e, _v, ctx) => {
      if (ctx?.previous !== undefined) qc.setQueryData(keys.approvals(), ctx.previous);
    },
    onSettled: () => {
      void qc.invalidateQueries({ queryKey: keys.approvals() });
      void qc.invalidateQueries({ queryKey: keys.tasks() });
    },
  });
}

export function useTimesheetAction() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ action, reason }: { action: TimesheetAction; reason?: string }) => api.timesheetAction(action, reason),
    onSuccess: () => qc.invalidateQueries({ queryKey: keys.timesheet() }),
  });
}

/** User-safe message for any thrown value. */
export function errorMessage(error: unknown, fallback: string): string {
  return error instanceof ApiError ? error.message : fallback;
}
