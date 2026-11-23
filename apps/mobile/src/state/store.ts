import { useSyncExternalStore } from 'react';

/**
 * Minimal external store with selector subscriptions.
 *
 * Components re-render only when the slice they select changes (compared with
 * `Object.is`), which keeps large screens cheap without a state library.
 */
export interface Store<S> {
  get(): S;
  set(update: Partial<S> | ((prev: S) => Partial<S>)): void;
  subscribe(listener: () => void): () => void;
}

export function createStore<S extends object>(initial: S): Store<S> {
  let state = initial;
  const listeners = new Set<() => void>();
  return {
    get: () => state,
    set(update) {
      const patch = typeof update === 'function' ? update(state) : update;
      const next = { ...state, ...patch };
      const changed = (Object.keys(patch) as (keyof S)[]).some((k) => !Object.is(state[k], next[k]));
      if (!changed) return;
      state = next;
      listeners.forEach((l) => l());
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
}

export function useStore<S, T>(store: Store<S>, selector: (s: S) => T): T {
  return useSyncExternalStore(
    store.subscribe,
    () => selector(store.get()),
    () => selector(store.get()),
  );
}
