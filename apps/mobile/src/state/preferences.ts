import AsyncStorage from '@react-native-async-storage/async-storage';
import { ROLE_TEMPLATES } from '@nforce/core';
import { z } from 'zod';

import { liveConfigured } from '@/data/supabase';
import { ACCENT_IDS } from '@/design/accents';

import { createStore, useStore } from './store';

/**
 * User preferences, persisted locally and validated on load so a corrupt or
 * outdated payload can never crash the app — it simply falls back to defaults.
 */
const HOME_WIDGETS = ['clock', 'next_shift', 'my_work', 'balances', 'team_pulse', 'approvals', 'org_metrics'] as const;

const PreferencesSchema = z.object({
  appearance: z.enum(['system', 'light', 'dark']),
  locale: z.enum(['system', 'en', 'fil', 'es']),
  haptics: z.boolean(),
  /** Platform look. `auto` follows the OS; overrides exist for design review. */
  flavor: z.enum(['auto', 'ios', 'android']),
  /** Demo persona: which workspace profile the sample session uses. */
  persona: z.enum(ROLE_TEMPLATES),
  reduceMotion: z.boolean(),
  accent: z.enum(ACCENT_IDS),
  density: z.enum(['comfortable', 'compact']),
  /** Desktop sidebar: full labels or an icon-only rail. */
  sidebar: z.enum(['expanded', 'rail']),
  /** Home dashboard layout: widget order and hidden widgets. */
  homeOrder: z.array(z.enum(HOME_WIDGETS)).max(20),
  homeHidden: z.array(z.enum(HOME_WIDGETS)).max(20),
  /** Which backend the app talks to: the sample organization, or the live Supabase workspace. */
  backend: z.enum(['demo', 'live']),
  /** Selected live workspace (organization id); empty picks the first one. */
  workspaceId: z.string().max(64),
});

export type Preferences = z.infer<typeof PreferencesSchema>;

export const DEFAULT_PREFERENCES: Preferences = {
  appearance: 'system',
  locale: 'system',
  haptics: true,
  flavor: 'auto',
  persona: 'supervisor',
  reduceMotion: false,
  accent: 'nforce',
  density: 'comfortable',
  sidebar: 'expanded',
  homeOrder: [],
  homeHidden: [],
  backend: liveConfigured ? 'live' : 'demo',
  workspaceId: '',
};

const STORAGE_KEY = 'nforce.preferences.v2';

export const preferencesStore = createStore<Preferences & { hydrated: boolean }>({
  ...DEFAULT_PREFERENCES,
  hydrated: false,
});

export async function hydratePreferences(): Promise<void> {
  try {
    const raw = await AsyncStorage.getItem(STORAGE_KEY);
    const parsed = raw === null ? null : PreferencesSchema.partial().safeParse(JSON.parse(raw));
    preferencesStore.set({ ...(parsed?.success === true ? parsed.data : {}), hydrated: true });
  } catch {
    preferencesStore.set({ hydrated: true });
  }
}

export function setPreference<K extends keyof Preferences>(key: K, value: Preferences[K]): void {
  preferencesStore.set({ [key]: value } as Partial<Preferences>);
  const { hydrated: _ignored, ...persisted } = preferencesStore.get();
  AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(persisted)).catch(() => {
    // Persistence is best-effort; the in-memory preference still applies.
  });
}

export const usePreference = <K extends keyof Preferences>(key: K): Preferences[K] =>
  useStore(preferencesStore, (s) => s[key]);

export function resetAppearance(): void {
  for (const key of ['appearance', 'accent', 'density', 'flavor', 'sidebar', 'homeOrder', 'homeHidden'] as const) {
    setPreference(key, DEFAULT_PREFERENCES[key]);
  }
}

export const usePreferencesHydrated = (): boolean => useStore(preferencesStore, (s) => s.hydrated);
