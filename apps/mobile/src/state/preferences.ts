import AsyncStorage from '@react-native-async-storage/async-storage';
import { ROLE_TEMPLATES } from '@nforce/core';
import { z } from 'zod';

import { createStore, useStore } from './store';

/**
 * User preferences, persisted locally and validated on load so a corrupt or
 * outdated payload can never crash the app — it simply falls back to defaults.
 */
const PreferencesSchema = z.object({
  appearance: z.enum(['system', 'light', 'dark']),
  locale: z.enum(['system', 'en', 'fil', 'es']),
  haptics: z.boolean(),
  /** Platform look. `auto` follows the OS; overrides exist for design review. */
  flavor: z.enum(['auto', 'ios', 'android']),
  /** Demo persona: which workspace profile the sample session uses. */
  persona: z.enum(ROLE_TEMPLATES),
  reduceMotion: z.boolean(),
});

export type Preferences = z.infer<typeof PreferencesSchema>;

export const DEFAULT_PREFERENCES: Preferences = {
  appearance: 'system',
  locale: 'system',
  haptics: true,
  flavor: 'auto',
  persona: 'supervisor',
  reduceMotion: false,
};

const STORAGE_KEY = 'nforce.preferences.v1';

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

export const usePreferencesHydrated = (): boolean => useStore(preferencesStore, (s) => s.hydrated);
