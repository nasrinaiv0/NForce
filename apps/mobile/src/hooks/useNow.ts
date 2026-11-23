import { useEffect, useState } from 'react';
import { AppState } from 'react-native';

/**
 * Current time, re-rendering every `intervalMs` while `active`. Pauses when
 * the app is backgrounded (battery) and re-syncs immediately on resume.
 */
export function useNow(intervalMs: number, active = true): Date {
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    if (!active) return;
    const tick = () => setNow(new Date());
    let timer: ReturnType<typeof setInterval> | undefined;
    const start = () => {
      if (timer === undefined) timer = setInterval(tick, intervalMs);
    };
    const stop = () => {
      if (timer !== undefined) clearInterval(timer);
      timer = undefined;
    };
    const kick = setTimeout(tick, 0); // sync immediately when (re)activated
    start();
    const sub = AppState.addEventListener('change', (state) => {
      if (state === 'active') {
        tick();
        start();
      } else {
        stop();
      }
    });
    return () => {
      clearTimeout(kick);
      stop();
      sub.remove();
    };
  }, [intervalMs, active]);
  return now;
}
