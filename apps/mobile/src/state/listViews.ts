import AsyncStorage from '@react-native-async-storage/async-storage';
import type { Condition, MatchMode, SortSpec } from '@nforce/core';
import { z } from 'zod';

import { createStore, useStore } from './store';

/**
 * Each list remembers how its owner last sorted and filtered it (per device).
 * Stored separately from preferences and validated on load: a corrupt or
 * outdated entry is dropped, never crashes a screen.
 */
export interface ListView {
  readonly sort?: SortSpec;
  readonly conditions: readonly Condition[];
  readonly match: MatchMode;
  /** Selected quick filter, when the list has one. */
  readonly quick?: string;
}

const OPERATOR = z.enum([
  'contains', 'not_contains', 'is', 'is_not', 'starts_with', 'any_of', 'none_of', 'eq', 'neq', 'gt', 'gte', 'lt', 'lte',
  'between', 'on', 'before', 'after', 'on_or_before', 'on_or_after', 'is_true', 'is_false', 'is_empty', 'not_empty',
]);
const ViewSchema = z.object({
  sort: z.object({ key: z.string().max(64), direction: z.enum(['asc', 'desc']) }).optional(),
  conditions: z
    .array(
      z.object({
        id: z.string().max(64),
        field: z.string().max(64),
        op: OPERATOR,
        value: z.union([z.string().max(200), z.number(), z.array(z.string().max(100)).max(50)]).optional(),
        value2: z.union([z.string().max(200), z.number()]).optional(),
      }),
    )
    .max(20),
  match: z.enum(['all', 'any']),
  quick: z.string().max(64).optional(),
});
const STORAGE_KEY = 'nforce.listviews.v1';

export const EMPTY_VIEW: ListView = { conditions: [], match: 'all' };

const store = createStore<{ views: Readonly<Record<string, ListView>>; hydrated: boolean }>({ views: {}, hydrated: false });

export async function hydrateListViews(): Promise<void> {
  try {
    const raw = await AsyncStorage.getItem(STORAGE_KEY);
    const parsed = raw === null ? {} : (JSON.parse(raw) as Record<string, unknown>);
    const views: Record<string, ListView> = {};
    for (const [key, value] of Object.entries(parsed)) {
      const v = ViewSchema.safeParse(value);
      if (v.success) views[key] = v.data as ListView;
    }
    store.set({ views, hydrated: true });
  } catch {
    store.set({ hydrated: true });
  }
}

export function saveListView(key: string, view: ListView): void {
  const views = { ...store.get().views, [key]: view };
  store.set({ views });
  AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(views)).catch(() => {
    // Best effort: the view still applies for this session.
  });
}

export const useListViewState = (key: string): ListView => useStore(store, (s) => s.views[key] ?? EMPTY_VIEW);
