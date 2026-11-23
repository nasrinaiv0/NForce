import type { Session } from '@supabase/supabase-js';

import { fetchWorkspaces, toApiError, type Workspace } from '@/data/liveDataset';
import { liveConfigured, supabase } from '@/data/supabase';

import { preferencesStore, setPreference } from './preferences';
import { createStore, useStore } from './store';

/**
 * Live-mode session: who is signed in and which workspaces they belong to.
 * In demo mode (or when Supabase is not configured) this stays signed out and
 * the app uses the sample organization.
 */
export interface BackendState {
  readonly auth: 'unknown' | 'signed_out' | 'signed_in';
  readonly userId?: string;
  readonly email?: string;
  /** undefined while loading. */
  readonly workspaces?: readonly Workspace[];
  readonly error?: string;
}

export const backendStore = createStore<BackendState>({ auth: liveConfigured ? 'unknown' : 'signed_out' });
export const useBackend = <T>(selector: (s: BackendState) => T): T => useStore(backendStore, selector);

/** True when the app should talk to Supabase rather than the demo. */
export const isLive = (): boolean => liveConfigured && preferencesStore.get().backend === 'live';

/** The workspace in use: the saved choice when still valid, else the first. */
export function activeWorkspace(state: BackendState = backendStore.get()): Workspace | undefined {
  const list = state.workspaces ?? [];
  const saved = preferencesStore.get().workspaceId;
  return list.find((w) => w.organizationId === saved) ?? list[0];
}

let started = false;

async function applySession(session: Session | null): Promise<void> {
  if (session === null) {
    backendStore.set({ auth: 'signed_out', userId: undefined, email: undefined, workspaces: undefined, error: undefined });
    return;
  }
  backendStore.set({ auth: 'signed_in', userId: session.user.id, email: session.user.email ?? '', workspaces: undefined, error: undefined });
  await reloadWorkspaces();
}

export async function reloadWorkspaces(): Promise<void> {
  try {
    const workspaces = await fetchWorkspaces(supabase());
    backendStore.set({ workspaces, error: undefined });
  } catch (error) {
    backendStore.set({ workspaces: [], error: error instanceof Error ? error.message : String(error) });
  }
}

/** Start listening to Supabase Auth (once). Safe to call in demo mode. */
export function startBackend(): void {
  if (started || !liveConfigured) return;
  started = true;
  const auth = supabase().auth;
  void auth.getSession().then(({ data }) => applySession(data.session));
  auth.onAuthStateChange((event, session) => {
    // Token refreshes keep the same user and workspaces.
    if (event === 'TOKEN_REFRESHED' && session?.user.id === backendStore.get().userId) return;
    // Defer: Supabase recommends not awaiting other calls inside this callback.
    setTimeout(() => void applySession(session), 0);
  });
}

// ------------------------------------------------------------------ actions

const fail = (error: { message: string; code?: string } | null) => {
  if (error !== null) throw toApiError({ code: error.code ?? '', message: error.message });
};

export async function signIn(email: string, password: string): Promise<void> {
  const { error } = await supabase().auth.signInWithPassword({ email: email.trim(), password });
  fail(error);
}

/** Returns true when the account still needs its email confirmed. */
export async function signUp(name: string, email: string, password: string, redirectTo?: string): Promise<boolean> {
  const { data, error } = await supabase().auth.signUp({
    email: email.trim(),
    password,
    options: { data: { full_name: name.trim() }, ...(redirectTo !== undefined ? { emailRedirectTo: redirectTo } : {}) },
  });
  fail(error);
  return data.session === null;
}

export async function sendPasswordReset(email: string, redirectTo?: string): Promise<void> {
  const { error } = await supabase().auth.resetPasswordForEmail(email.trim(), redirectTo !== undefined ? { redirectTo } : undefined);
  fail(error);
}

export async function signOut(): Promise<void> {
  await supabase().auth.signOut();
}

export async function createWorkspace(name: string, timeZone: string, jobTitle: string): Promise<void> {
  const { data, error } = await supabase().rpc('create_organization', { p_name: name.trim(), p_time_zone: timeZone, p_job_title: jobTitle.trim() || 'Owner' });
  fail(error);
  if (typeof data === 'string') setPreference('workspaceId', data);
  await reloadWorkspaces();
}

export function switchToDemo(): void {
  setPreference('backend', 'demo');
}

export function switchToLive(): void {
  setPreference('backend', 'live');
}
